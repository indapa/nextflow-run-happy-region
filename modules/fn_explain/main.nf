nextflow.enable.types = true

// One explanation per false-negative truth variant (the agent's structured output).
record FnExplanation {
    sample_id: String     // echoed from the input
    variant: String       // echoed from the input: CHROM:POS:REF:ALT
    category: String      // one of the categories listed in the agent instruction
    explanation: String   // 1-3 sentences
    evidence: String      // the specific lines/fields the explanation rests on
    confidence: Float     // 0.0-1.0
}

// Deterministic step: find FN truth variants in the hap.py VCF and gather the
// evidence around each one. Read-level evidence comes from the query BAM, because
// most false negatives have no record in the query VCF.
// No reasoning here.
process EXTRACT_FN_EVIDENCE {
    tag sample_id
    conda 'bioconda::bcftools=1.21 bioconda::samtools=1.21'

    input:
    record(
        sample_id: String,
        vcf: Path,
        vcf_index: Path,
        query_vcf: Path,
        query_index: Path,
        query_bam: Path,
        query_bam_index: Path
    )
    ref: Path
    ref_index: Path
    max_fn: Integer
    window: Integer

    output:
    record(
        sample_id: sample_id,
        evidence: files('fn/*.txt', optional: true)
    )

    script:
    """
    mkdir -p fn

    # FN = truth variant hap.py marked BD=FN in the TRUTH column (sample index 0).
    # Fixed-seed shuffle so the capped subset is spread across the genome and reproducible.
    bcftools query -i 'FMT/BD[0]="FN"' -f '%CHROM\\t%POS\\t%REF\\t%ALT\\n' ${vcf} \\
        | shuf -n ${max_fn} --random-source=<(yes) \\
        > fn_sites.tsv

    while IFS=\$'\\t' read -r chrom pos ref_allele alt_allele; do
        start=\$(( pos > ${window} ? pos - ${window} : 1 ))
        end=\$(( pos + \${#ref_allele} + ${window} ))
        region="\${chrom}:\${start}-\${end}"
        # the variant itself, padded by 5 bp so shifted indel representations are included
        site_start=\$(( pos > 5 ? pos - 5 : 1 ))
        site_end=\$(( pos + \${#ref_allele} + 5 ))
        site="\${chrom}:\${site_start}-\${site_end}"
        locus="\${chrom}:\${pos}-\${pos}"
        {
            echo "## TRUTH VARIANT (false negative)"
            echo "\${chrom}:\${pos}:\${ref_allele}:\${alt_allele}"
            echo
            echo "## HAP.PY RECORDS IN \${region}"
            echo "## columns: CHROM POS REF ALT TRUTH(GT:BD:BK:BVT:BLT) QUERY(GT:BD:BK:BVT:BLT)"
            bcftools query -r "\${region}" -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%GT:%BD:%BK:%BVT:%BLT]\\n' ${vcf}
            echo
            echo "## QUERY VCF: FILTER AND DEPTH FIELD DEFINITIONS"
            bcftools view -h ${query_vcf} | grep -E '^##FILTER=|^##(FORMAT|INFO)=<ID=(AD|DP|GQ|MQ),' || true
            echo
            echo "## QUERY VCF RECORDS IN \${region} (all FILTER values, with header columns)"
            bcftools view -h ${query_vcf} | tail -n 1
            bcftools view -H -r "\${region}" ${query_vcf}
            echo
            echo "## REFERENCE SEQUENCE \${region}"
            samtools faidx ${ref} "\${region}"
            echo
            echo "## QUERY BAM: DEPTH (all MAPQ; excludes secondary, QC-fail and duplicate reads)"
            samtools depth -a --reference ${ref} -r "\${region}" ${query_bam} \\
                | awk -v p="\${pos}" '{ s += \$3; if (min == "" || \$3 < min) min = \$3; if (\$2 == p) at = \$3 }
                    END { if (NR) printf "depth_at_site=%s window_mean_depth=%.1f window_min_depth=%s\\n", at, s / NR, min; else print "no coverage data" }'
            echo
            echo "## QUERY BAM: READS OVERLAPPING THE SITE, BY MAPPING QUALITY (primary alignments)"
            all=\$(samtools view -c -F 0x900 -T ${ref} ${query_bam} "\${locus}")
            mq1=\$(samtools view -c -F 0x900 -q 1 -T ${ref} ${query_bam} "\${locus}")
            mq20=\$(samtools view -c -F 0x900 -q 20 -T ${ref} ${query_bam} "\${locus}")
            dup=\$(samtools view -c -F 0x900 -f 0x400 -T ${ref} ${query_bam} "\${locus}")
            echo "reads=\${all} mapq0=\$(( all - mq1 )) mapq_ge20=\${mq20} duplicates=\${dup}"
            echo
            echo "## QUERY BAM: ALLELE PILEUP IN \${site} (bcftools mpileup, MAPQ>=1, BQ>=13)"
            echo "## columns: CHROM POS REF ALT DP AD(ref,alts) ADF(forward) ADR(reverse); <*> = any other allele"
            bcftools mpileup -f ${ref} -r "\${site}" -q 1 -d 1000 \\
                -a FORMAT/DP,FORMAT/AD,FORMAT/ADF,FORMAT/ADR ${query_bam} 2>/dev/null \\
                | bcftools query -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%DP\\t%AD\\t%ADF\\t%ADR]\\n'
        } > "fn/\${chrom}_\${pos}.txt"
    done < fn_sites.tsv
    """

    stub:
    """
    mkdir -p fn
    printf '## TRUTH VARIANT (false negative)\\nchr1:1000:A:G\\n' > fn/chr1_1000.txt
    """
}

// Reasoning step: one agent task per false negative. No tools: all evidence is in the prompt.
agent EXPLAIN_FN {
    model 'anthropic/claude-sonnet-4-6'
    maxIterations 3

    instruction '''\
        You are a germline variant-calling benchmarking expert. You are given ONE truth
        variant that hap.py (vcfeval engine, --pass-only) scored as a false negative: it
        is in the truth set but was not matched by a PASS call in the query VCF.
        Explain the most likely reason, using ONLY the evidence provided.

        How to read the evidence:
          - hap.py fields: BD = decision (TP/FP/FN/N), BK = match kind
            (gm = genotype match, am = allele match but genotype mismatch,
            lm = local match: a different variant nearby, . = no match),
            BVT = SNP/INDEL, BLT = het/homalt/hetalt.
          - Query VCF records are shown for ALL FILTER values. hap.py ran with
            --pass-only, so a non-PASS query call counts as not called.
          - The reference sequence shows the local context (homopolymers, short
            tandem repeats, low complexity, GC extremes).
          - Query VCF read fields: where a query record exists, FORMAT/AD is the
            read count per allele (reference first, then each ALT in order) and
            FORMAT/DP is the total depth, as the caller saw them. The FILTER and
            field definitions from the VCF header are included.
          - Query BAM sections: these are computed from the alignments and exist for
            every site, including sites with no query VCF record.
              depth            depth at the site against the mean and minimum
                               across the window
              mapping quality  how many reads over the site are MAPQ 0, MAPQ >= 20,
                               or duplicates
              allele pileup    per-position read counts for the reference allele
                               and each alternate allele (AD), split by strand
                               (ADF, ADR). Indels appear as their own records and
                               may be left-shifted or written with a different REF
                               span than the truth variant, so compare the inserted
                               or deleted bases, not just the position.
          - The caller's AD/DP can differ from the BAM pileup, because callers
            realign and filter reads. If they disagree, say so.

        Decide in this order, and choose exactly one category:
          FILTERED_IN_QUERY        the variant is in the query VCF but FILTER is not PASS
          GENOTYPE_MISMATCH        the allele was called with the wrong zygosity (BK=am)
          ALLELE_MISMATCH          a different allele or representation was called at or
                                   near the site (BK=lm, or a nearby FP)
          LOW_COVERAGE             no call, and depth at the site is too low to support
                                   one, in absolute terms or against the window mean
          LOW_MAPQ                 no call, and most reads over the site are MAPQ 0 or
                                   below 20
          NO_READ_SUPPORT          no call; depth and mapping quality are adequate, but
                                   no or almost no reads carry the truth allele
          ALT_SUPPORTED_NOT_CALLED no call, although reads do carry the truth allele
          INSUFFICIENT_EVIDENCE    the evidence is missing, contradictory or unreadable

        Rules:
          - Quote numbers, never impressions: depth, read counts by MAPQ, and the
            alternate-allele fraction (alt AD / total AD). Say whether each number
            comes from the BAM sections or from a query VCF record.
          - For ALT_SUPPORTED_NOT_CALLED, say what may have stopped the caller:
            a skewed allele fraction, support on one strand only, a homopolymer or
            tandem repeat, or clustered nearby variants.
          - For NO_READ_SUPPORT, say that the cause cannot be settled from this
            data: it may be an alignment artefact, a truth-set error or a sample
            mismatch.
          - For FILTERED_IN_QUERY, name the FILTER value and say what in the record
            (DP, AD, allele fraction, GQ) most likely triggered it.
          - For GENOTYPE_MISMATCH, quote AD and the allele fraction, and say whether
            they favour the truth genotype or the called one.
          - In `evidence`, quote the exact records, counts or sequence your
            explanation rests on.
          - Set `confidence` between 0 and 1. A category read directly from a record
            or a clear count deserves high confidence; an inference from sequence
            context alone does not.
          - Echo `sample_id` and `variant` exactly as given.
        '''.stripIndent()

    input:
    record(
        sample_id: String,
        variant: String,
        evidence: String
    )

    output:
    result: FnExplanation

    prompt:
    """
    Explain this false negative.

    sample_id: ${sample_id}
    variant: ${variant}

    ${evidence}
    """
}
