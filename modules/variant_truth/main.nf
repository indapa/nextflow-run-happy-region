nextflow.enable.types = true

process RUN_HAPPY_REGION {
    tag sample_id
    container 'jmcdani20/hap.py:v0.3.12'

    errorStrategy 'retry'
    maxRetries 2
    // Give larger chromosomes more juice on retries if they time out
    cpus 4 * task.attempt
    memory 16.GB * task.attempt

    input:
    record(
        sample_id: String,
        truth_vcf: Path,
        truth_index: Path,
        query_vcf: Path,
        query_index: Path
    )
    region_bed: Path
    ref: Path
    ref_index: Path

    output:
    record(
        sample_id: sample_id,
        summary: file("${sample_id}.happy.output.summary.csv"),
        extended: file("${sample_id}.happy.output.extended.csv"),
        rocs: files("${sample_id}.happy.output.roc.*", optional: true),
        vcf: file("${sample_id}.happy.output.vcf.gz"),
        vcf_index: file("${sample_id}.happy.output.vcf.gz.tbi")
    )

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
