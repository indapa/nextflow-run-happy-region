#!/usr/local/bin/nextflow

include {RUN_HAPPY_REGION} from './modules/variant_truth/'



   

workflow {
    ch_samples = channel.fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)

    happy_prs_ch = ch_samples.map { row ->
        tuple(
            row.sample_id, 
            file(row.truth_vcf), 
            file(row.truth_index), 
            file(row.query_vcf), 
            file(row.query_index), 
            
            
        )
    }

    // Convert file path parameters to file objects (Value Channel behavior)
    ch_bed = file(params.region_bed, checkIfExists: true)
    ch_ref = file(params.ref, checkIfExists: true)
    ch_fai = file(params.ref_index, checkIfExists: true)
    //happy_prs_ch.view()
    RUN_HAPPY_REGION(happy_prs_ch, ch_bed, ch_ref, ch_fai)
    
    
 
}