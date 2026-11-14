nextflow.enable.types = true

// One explanation per false-positive query call (the agent's structured output).
record FpExplanation {
    sample_id: String     // echoed from the input
    variant: String       // echoed from the input: CHROM:POS:REF:ALT
    category: String      // one of the categories listed in the agent instruction
    explanation: String   // 1-3 sentences
    evidence: String      // the specific lines/fields the explanation rests on
    confidence: Float     // 0.0-1.0
}

// Deterministic step: find FP query calls in the hap.py VCF and gather the
// evidence around each one. Unlike a false negative, a false positive always has
// a query VCF record, so the caller's own QUAL/GQ/AD are available; the BAM adds
// read-level checks for mismapping and strand bias.
// No reasoning here.
process EXTRACT_FP_EVIDENCE {
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
    max_fp: Integer
    window: Integer

    output:
    record(
        sample_id: sample_id,
        evidence: files('fp/*.txt', optional: true)
    )

    script:
    """
    mkdir -p fp

    # FP = query call hap.py marked BD=FP in the QUERY column (sample index 1).
    # Fixed-seed shuffle so the capped subset is spread across the genome and reproducible.
    bcftools query -i 'FMT/BD[1]="FP"' -f '%CHROM\\t%POS\\t%REF\\t%ALT\\n' ${vcf} \\
        | shuf -n ${max_fp} --random-source=<(yes) \\
        > fp_sites.tsv

    while IFS=\$'\\t' read -r chrom pos ref_allele alt_allele; do
        start=\$(( pos > ${window} ? pos - ${window} : 1 ))
        end=\$(( pos + \${#ref_allele} + ${window} ))
        region="\${chrom}:\${start}-\${end}"
        # the call itself, padded by 5 bp so shifted indel representations are included
        site_start=\$(( pos > 5 ? pos - 5 : 1 ))
        site_end=\$(( pos + \${#ref_allele} + 5 ))
        site="\${chrom}:\${site_start}-\${site_end}"
        locus="\${chrom}:\${pos}-\${pos}"
        {
            echo "## QUERY CALL (false positive)"
            echo "\${chrom}:\${pos}:\${ref_allele}:\${alt_allele}"
            echo
            echo "## HAP.PY RECORDS IN \${region}"
            echo "## columns: CHROM POS REF ALT TRUTH(GT:BD:BK:BVT:BLT) QUERY(GT:BD:BK:BVT:BLT)"
            bcftools query -r "\${region}" -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%GT:%BD:%BK:%BVT:%BLT]\\n' ${vcf}
            echo
            echo "## QUERY VCF: FILTER AND FIELD DEFINITIONS"
            bcftools view -h ${query_vcf} | grep -E '^##FILTER=|^##(FORMAT|INFO)=<ID=(AD|DP|GQ|MQ|VAF|PL|QD|FS|SOR),' || true
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
            supp=\$(samtools view -c -f 0x800 -T ${ref} ${query_bam} "\${locus}")
            echo "reads=\${all} mapq0=\$(( all - mq1 )) mapq_ge20=\${mq20} duplicates=\${dup} supplementary=\${supp}"
            echo
            echo "## QUERY BAM: ALLELE PILEUP IN \${site}, ALL MAPPED READS (bcftools mpileup, MAPQ>=0, BQ>=13)"
            echo "## columns: CHROM POS REF ALT DP AD(ref,alts) ADF(forward) ADR(reverse); <*> = any other allele"
            bcftools mpileup -f ${ref} -r "\${site}" -q 0 -d 1000 \\
                -a FORMAT/DP,FORMAT/AD,FORMAT/ADF,FORMAT/ADR ${query_bam} 2>/dev/null \\
                | bcftools query -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%DP\\t%AD\\t%ADF\\t%ADR]\\n'
            echo
            echo "## QUERY BAM: ALLELE PILEUP IN \${site}, CONFIDENTLY MAPPED READS ONLY (MAPQ>=20, BQ>=13)"
            echo "## compare with the section above: alt support that disappears here comes from poorly mapped reads"
            bcftools mpileup -f ${ref} -r "\${site}" -q 20 -d 1000 \\
                -a FORMAT/DP,FORMAT/AD,FORMAT/ADF,FORMAT/ADR ${query_bam} 2>/dev/null \\
                | bcftools query -f '%CHROM\\t%POS\\t%REF\\t%ALT[\\t%DP\\t%AD\\t%ADF\\t%ADR]\\n'
        } > "fp/\${chrom}_\${pos}.txt"
    done < fp_sites.tsv
    """

    stub:
    """
    mkdir -p fp
    printf '## QUERY CALL (false positive)\\nchr1:2000:C:T\\n' > fp/chr1_2000.txt
    """
}

// Reasoning step: one agent task per false positive. No tools: all evidence is in the prompt.
agent EXPLAIN_FP {
    model 'anthropic/claude-sonnet-4-6'
    maxIterations 3

    instruction '''\
        You are a germline variant-calling benchmarking expert. You are given ONE query
        call that hap.py (vcfeval engine, --pass-only) scored as a false positive: it is
        a PASS call in the query VCF that does not match the truth set inside the
        confident regions. Explain the most likely reason, using ONLY the evidence
        provided.

        How to read the evidence:
          - hap.py fields: BD = decision (TP/FP/FN/N), BK = match kind
            (gm = genotype match, am = allele match but genotype mismatch,
            lm = local match: a different variant nearby, . = no match),
            BVT = SNP/INDEL, BLT = het/homalt/hetalt. The QUERY column carries the
            FP decision; the TRUTH column shows what the truth set has at that
            record, if anything.
          - hap.py also counts a genotype mismatch (BK=am) as both a false negative
            and a false positive, and a different allele or representation at the
            same locus (BK=lm) the same way. Check this first.
          - Query VCF records are shown for ALL FILTER values, with the full FORMAT
            fields (typically GT, GQ, DP, AD, VAF, PL) and QUAL. FORMAT/AD is the
            read count per allele (reference first, then each ALT in order) as the
            caller saw it.
          - The reference sequence shows the local context (homopolymers, short
            tandem repeats, low complexity, GC extremes).
          - Query BAM sections are computed from the alignments:
              depth            depth at the site against the mean and minimum
                               across the window
              mapping quality  how many reads over the site are MAPQ 0, MAPQ >= 20,
                               duplicates or supplementary alignments
              allele pileups   per-position read counts per allele (AD), split by
                               strand (ADF, ADR), once for all mapped reads and
                               once for MAPQ >= 20 only. Alt support that is present
                               in the first and gone in the second comes from
                               poorly mapped reads (paralogs, segmental duplications).
                               Indels may be left-shifted or written with a different
                               REF span than the call, so compare the inserted or
                               deleted bases, not just the position.
          - The caller's AD/DP can differ from the BAM pileup, because callers
            realign and filter reads. If they disagree, say so.

        Decide in this order, and choose exactly one category:
          GENOTYPE_MISMATCH        the truth has the same allele with a different
                                   zygosity (BK=am)
          ALLELE_MISMATCH          the truth has a different allele or representation
                                   at or near the site (BK=lm, or a nearby FN)
          MISMAPPED_READS          alt support comes mostly from MAPQ 0 / MAPQ < 20
                                   reads and largely disappears at MAPQ >= 20
          STRAND_BIAS              alt-supporting reads are almost all on one strand
          REPEAT_ARTIFACT          the call sits in a homopolymer, tandem repeat or
                                   low-complexity sequence, and alt support is weak
                                   or inconsistent across nearby positions
          LOW_ALT_SUPPORT          few alt reads or a low allele fraction for the
                                   called genotype, with no clearer cause above
          SUPPORTED_NOT_IN_TRUTH   strong, balanced alt support from well-mapped reads
                                   on both strands; the call may be real and missing
                                   from the truth set
          INSUFFICIENT_EVIDENCE    the evidence is missing, contradictory or unreadable

        Rules:
          - Quote numbers, never impressions: QUAL, GQ, depth, read counts by MAPQ,
            alt reads per strand, and the alternate-allele fraction
            (alt AD / total AD). Say whether each number comes from the BAM
            sections or from the query VCF record.
          - For GENOTYPE_MISMATCH and ALLELE_MISMATCH, quote the TRUTH and QUERY
            columns of the hap.py record.
          - For MISMAPPED_READS, quote alt AD from both pileups.
          - For STRAND_BIAS, quote alt ADF and ADR.
          - For REPEAT_ARTIFACT, quote the repeat from the reference sequence.
          - For SUPPORTED_NOT_IN_TRUTH, say that this cannot be settled from this
            data: it may be a truth-set gap, a sample mismatch or a systematic
            artefact. Do not claim the truth set is wrong.
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
    result: FpExplanation

    prompt:
    """
    Explain this false positive.

    sample_id: ${sample_id}
    variant: ${variant}

    ${evidence}
    """
}
