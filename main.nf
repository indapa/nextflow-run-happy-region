#!/usr/bin/env nextflow

nextflow.enable.types = true

include { RUN_HAPPY_REGION } from './modules/variant_truth'

params {
    // CSV samplesheet: sample_id,truth_vcf,truth_index,query_vcf,query_index
    input: Channel<HappySample>
    // BED file restricting the comparison regions
    region_bed: Path
    // Reference FASTA and its .fai index
    ref: Path = 's3://ngi-igenomes/igenomes/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta/Homo_sapiens_assembly38.fasta'
    ref_index: Path = 's3://ngi-igenomes/igenomes/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta/Homo_sapiens_assembly38.fasta.fai'
    // Output directory (mapped to outputDir in nextflow.config)
    outdir: String = 'results'
}

workflow {
    main:
    ch_happy = RUN_HAPPY_REGION(params.input, params.region_bed, params.ref, params.ref_index)

    publish:
    happy = ch_happy
}

output {
    happy: Channel<Record> {
        path { r -> r.sample_id }
    }
}

record HappySample {
    sample_id: String
    truth_vcf: Path
    truth_index: Path
    query_vcf: Path
    query_index: Path
}
