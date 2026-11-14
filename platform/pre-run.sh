# Seqera Platform pre-run script for this pipeline.
#
# Platform runs this in the head job before Nextflow starts. It cannot read the
# script from the repo, so paste this file into the Launchpad pipeline
# (Edit > Advanced options > Pre-run script), or pass it with
# `tw launch ... --pre-run platform/pre-run.sh`.
#
# Requires the head job's IAM role to allow secretsmanager:GetSecretValue on
# arn:aws:secretsmanager:us-west-1:<account>:secret:anthropic-api-key-*

# Nextflow version required by manifest.nextflowVersion
export NXF_VER=26.10.6
# The pipeline uses static typing (typed params, records, agents), which only the
# v2 (strict) syntax parser understands. Force it in case the environment sets v1.
export NXF_SYNTAX_PARSER=v2

# Anthropic API key for the EXPLAIN_FN / EXPLAIN_FP agents (--explain_fn, --explain_fp)
export ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value \
    --secret-id anthropic-api-key \
    --region us-west-1 \
    --query SecretString --output text)
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "ERROR: could not read anthropic-api-key from Secrets Manager" >&2
    exit 1
fi
