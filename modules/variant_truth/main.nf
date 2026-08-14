process RUN_HAPPY_REGION {
    tag "${sample_id}"
    publishDir { "${params.outdir}/${sample_id}" }, mode: 'copy', overwrite: true
    container 'jmcdani20/hap.py:v0.3.12'

    errorStrategy 'retry'
    maxRetries 2
    // Give larger chromosomes more juice on retries if they time out
    cpus { 4 * task.attempt }
    memory { 16.GB * task.attempt }

    input:
    tuple val(sample_id), path(truth_vcf), path(truth_index), path(query_vcf), path(query_index),path(region_bed), path(ref), path(ref_index)

    output:
    tuple val(sample_id), path("*.summary.csv"), emit: summary
    tuple val(sample_id), path("*.extended.csv"), emit: extended
    tuple val(sample_id), path("*.roc.*"), emit: rocs
    tuple val(sample_id), path("*.vcf.gz"), emit: vcf
    tuple val(sample_id),  path("*.vcf.gz.tbi"), emit: vcf_index

    script:
    def prefix = "${sample_id}.happy.output"
    """


    

    /opt/hap.py/bin/hap.py \\
        ${truth_vcf} \\
        ${query_vcf} \\
        -f ${region_bed} \\
        -r ${ref} \\
        -o ${prefix} \\
        --engine=vcfeval \\
        --pass-only \\
        --no-roc \\
        --threads ${task.cpus}
    """

    stub:
    def prefix = "${sample_id}.happy.output"
    """
    touch ${prefix}.summary.csv
    touch ${prefix}.extended.csv
    touch ${prefix}.roc.all.csv.gz
    touch ${prefix}.vcf.gz
    touch ${prefix}.vcf.gz.tbi
    """
}

