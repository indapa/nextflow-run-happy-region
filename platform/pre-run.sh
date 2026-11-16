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

# Turn off Nextflow secrets. Agent tasks (EXPLAIN_FN / EXPLAIN_FP) run on the
# local AgentExecutor, not AWS Batch, and Nextflow asks the secrets provider for
# every non-Batch task's secrets even when it declares none. On AWS Batch the
# provider is AwsSecretsProvider, which only serves Batch tasks, so agent tasks
# fail with "AwsSecretsProvider requires the use of the AWS Batch executor".
# The pipeline uses no Nextflow secrets: the API key comes from the variable below.
export NXF_ENABLE_SECRETS=false

# Anthropic API key for the EXPLAIN_FN / EXPLAIN_FP agents (--explain_fn, --explain_fp)
export ANTHROPIC_API_KEY=$(aws secretsmanager get-secret-value \
    --secret-id anthropic-api-key \
    --region us-west-1 \
    --query SecretString --output text)
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "ERROR: could not read anthropic-api-key from Secrets Manager" >&2
    exit 1
fi
