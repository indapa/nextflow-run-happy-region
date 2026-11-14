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
    restrict_regions: Boolean

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
    // -f marks the BED as the confident regions; calls outside it are scored UNK.
    // -T also restricts both VCFs to the BED before comparison (bcftools view -T),
    // so hap.py only compares and writes records inside the regions.
    // Not -R: hap.py 0.3.12 builds its -R command without the bcftools binary and
    // fails with "/bin/sh: view: not found" (fixed upstream in 0.3.15). In hap.py,
    // -R streams the whole VCF to a temp file first anyway, so -T is no slower.
    def region_args = restrict_regions ? "-T ${region_bed} -f ${region_bed}" : "-f ${region_bed}"
    """
    /opt/hap.py/bin/hap.py \\
        ${truth_vcf} \\
        ${query_vcf} \\
        ${region_args} \\
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
