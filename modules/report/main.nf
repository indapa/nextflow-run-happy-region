nextflow.enable.types = true

// Renders every EXPLAIN_FN / EXPLAIN_FP result in the run as one PDF:
// a summary of counts and categories, then one entry per variant.
// rows: one JSON object per explanation (see bin/explanations_pdf.py). collect
// passes an empty bag when no agent ran or nothing was explained; then no PDF is made.
process REPORT_PDF {
    conda 'conda-forge::python=3.12 conda-forge::reportlab=4.2.5 conda-forge::font-ttf-dejavu-sans-mono=2.37'
    cpus 1
    memory 2.GB

    input:
    rows: Bag<String>

    output:
    file('explanations.pdf', optional: true)

    script:
    if (rows.isEmpty())
        return 'echo "no explanations: skipping the PDF report"'
    // Quoted heredoc: the shell does not expand anything in the agents' text.
    // A JSON line can never equal the delimiter, so the text cannot end it early.
    """
    cat > explanations.jsonl <<'__NF_EXPLANATIONS_EOF__'
${rows.join('\n')}
__NF_EXPLANATIONS_EOF__

    explanations_pdf.py explanations.jsonl -o explanations.pdf
    """

    stub:
    rows.isEmpty() ? 'true' : 'touch explanations.pdf'
}
