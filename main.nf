#!/usr/bin/env nextflow

nextflow.enable.types = true

include { RUN_HAPPY_REGION } from './modules/variant_truth'
include { EXTRACT_FN_EVIDENCE ; EXPLAIN_FN ; FnExplanation } from './modules/fn_explain'
include { EXTRACT_FP_EVIDENCE ; EXPLAIN_FP ; FpExplanation } from './modules/fp_explain'

params {
    // CSV samplesheet: sample_id,truth_vcf,truth_index,query_vcf,query_index[,query_bam,query_bam_index]
    input: Channel<HappySample>
    // BED file restricting the comparison regions
    region_bed: Path
    // Restrict hap.py to the BED regions with -T (false: compare genome-wide, BED only as confident regions)
    restrict_regions: Boolean = true
    // Reference FASTA and its .fai index
    ref: Path = 's3://ngi-igenomes/igenomes/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta/Homo_sapiens_assembly38.fasta'
    ref_index: Path = 's3://ngi-igenomes/igenomes/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta/Homo_sapiens_assembly38.fasta.fai'
    // Output directory (mapped to outputDir in nextflow.config)
    outdir: String = 'results'
    // Ask an LLM agent to explain false negatives (needs query_bam columns and ANTHROPIC_API_KEY)
    explain_fn: Boolean = false
    // Maximum number of false negatives explained per sample (one LLM call each)
    max_fn: Integer = 50
    // Bases of context gathered either side of each false negative
    fn_window: Integer = 50
    // Ask an LLM agent to explain false positives (needs query_bam columns and ANTHROPIC_API_KEY)
    explain_fp: Boolean = false
    // Maximum number of false positives explained per sample (one LLM call each)
    max_fp: Integer = 50
    // Bases of context gathered either side of each false positive
    fp_window: Integer = 50
}

workflow {
    main:
    ch_happy = RUN_HAPPY_REGION(params.input, params.region_bed, params.ref, params.ref_index, params.restrict_regions)

    // hap.py output + the sample's query VCF and BAM, matched on sample_id.
    // Samples without a query BAM are skipped by both explanation steps.
    ch_bam_input = ch_happy
        .join(params.input, by: 'sample_id')
        .filter { r -> r.query_bam != null && r.query_bam_index != null }

    ch_explained = channel.empty()
    if (params.explain_fn) {
        ch_evidence = EXTRACT_FN_EVIDENCE(ch_bam_input, params.ref, params.ref_index, params.max_fn, params.fn_window)

        // one record per false negative; line 2 of each evidence file is CHROM:POS:REF:ALT
        ch_fn = ch_evidence.flatMap { r ->
            // evidence is empty when hap.py found no FNs; collect then emits nothing
            if (r.evidence.isEmpty())
                log.info "[${r.sample_id}] hap.py found no false negatives in the BED regions; nothing for EXPLAIN_FN to explain"
            r.evidence.collect { f ->
                record(sample_id: r.sample_id, variant: f.readLines()[1], evidence: f.text)
            }
        }

        ch_explained = EXPLAIN_FN(ch_fn)
    }

    ch_fp_explained = channel.empty()
    if (params.explain_fp) {
        ch_fp_evidence = EXTRACT_FP_EVIDENCE(ch_bam_input, params.ref, params.ref_index, params.max_fp, params.fp_window)

        // one record per false positive; line 2 of each evidence file is CHROM:POS:REF:ALT
        ch_fp = ch_fp_evidence.flatMap { r ->
            // evidence is empty when hap.py found no FPs; collect then emits nothing
            if (r.evidence.isEmpty())
                log.info "[${r.sample_id}] hap.py found no false positives in the BED regions; nothing for EXPLAIN_FP to explain"
            r.evidence.collect { f ->
                record(sample_id: r.sample_id, variant: f.readLines()[1], evidence: f.text)
            }
        }

        ch_fp_explained = EXPLAIN_FP(ch_fp)
    }

    publish:
    happy = ch_happy
    fn_explanations = ch_explained
    fp_explanations = ch_fp_explained
}

output {
    happy: Channel<Record> {
        path { r -> r.sample_id }
    }
    fn_explanations: Channel<FnExplanation> {
        index {
            path 'fn_explanations.csv'
            header true
        }
    }
    fp_explanations: Channel<FpExplanation> {
        index {
            path 'fp_explanations.csv'
            header true
        }
    }
}

record HappySample {
    sample_id: String
    truth_vcf: Path
    truth_index: Path
    query_vcf: Path
    query_index: Path
    // only needed with --explain_fn / --explain_fp
    query_bam: Path?
    query_bam_index: Path?
}
