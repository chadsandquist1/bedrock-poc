# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Terraform-managed AWS proof-of-concept for a RAG (Retrieval-Augmented Generation) pipeline using AWS Bedrock Knowledge Base with S3 Vectors as the vector store. It also includes Lambda functions for semantic/hybrid RAG search and an LLM-as-a-Judge evaluation framework.

## Prerequisites

- AWS CLI v2.30+ (with S3 Vectors support)
- Terraform >= 1.0
- Python 3.8+ with `jq` available on PATH
- AWS credentials configured with Bedrock access enabled

## Common Commands

### Terraform (run from `terraform/`)

```bash
cd terraform
terraform init
terraform plan
terraform apply
terraform destroy
```

### Post-deploy: upload docs and trigger ingestion

```bash
# Upload sample documents
aws s3 sync scripts/documents/ s3://$(cd terraform && terraform output -raw documents_bucket_name)/

# Get KB and DS IDs, then start ingestion
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 | jq -r '.knowledgeBaseSummaries[] | select(.name=="bedrock-rag-dev-knowledge-base") | .knowledgeBaseId')
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --region us-east-1 | jq -r '.dataSourceSummaries[0].dataSourceId')
aws bedrock-agent start-ingestion-job --knowledge-base-id $KB_ID --data-source-id $DS_ID --region us-east-1
```

### LLM-as-a-Judge evaluation script

```bash
cd scripts
pip install -r requirements.txt

# Create and monitor a new evaluation job
python llm_judge_evaluation.py --dataset sample-evaluation-dataset.jsonl

# Monitor an existing job
export EVALUATION_JOB_ARN='arn:aws:bedrock:...'
python llm_judge_evaluation.py
```

### Invoke RAG Lambdas manually

```bash
# Semantic search
aws lambda invoke --function-name bedrock-rag-dev-semantic-rag \
  --payload '{"query": "What is photosynthesis?"}' \
  --cli-binary-format raw-in-base64-out /dev/stdout

# Hybrid search (requires OpenSearch Serverless KB, not S3 Vectors)
aws lambda invoke --function-name bedrock-rag-dev-hybrid-rag \
  --payload '{"query": "What is photosynthesis?"}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

## Repository Structure

```
bedrock-poc/
├── .github/
│   └── workflows/
│       └── terraform.yml       # CI/CD: plan on PR, apply on merge to main
├── terraform/                  # All Terraform configuration
│   ├── main.tf                 # S3 buckets, IAM, S3 Vectors, Knowledge Base, Data Source
│   ├── lambda.tf               # Ingestion handler Lambda + CloudWatch log group
│   ├── lambda_rag.tf           # Semantic and Hybrid RAG test Lambdas
│   ├── cloudwatch_logging.tf   # CW Logs subscription filter → ingestion Lambda
│   ├── llmasjudge.tf           # S3 bucket + IAM role for LLM-as-a-Judge evaluations
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── terraform.tfvars.example
├── lambdas/                    # Lambda handler source code
│   ├── lambda_ingestion_handler.py
│   ├── lambda_semantic_rag_handler.py
│   └── lambda_hybrid_rag_handler.py
└── scripts/                    # Operational scripts and sample data
    ├── bootstrap-tf-backend.sh # One-time S3 + DynamoDB backend setup (already run)
    ├── llm_judge_evaluation.py
    ├── requirements.txt
    ├── sample-evaluation-dataset.jsonl
    └── documents/              # Sample RAG source documents
```

## Architecture

### Why `null_resource` for core resources?

S3 Vectors and Bedrock Knowledge Base with `S3_VECTORS` storage type are not fully supported by the Terraform AWS provider. These resources are created/destroyed via `local-exec` provisioners calling the AWS CLI directly. IDs are persisted to `/tmp/kb_id_<name>.txt` and `/tmp/ds_id_<name>.txt` for use during destroy.

### Lambda functions (all Python 3.11, source in `lambdas/`)

- **`lambda_ingestion_handler.py`** — Decodes gzipped/base64 CloudWatch Logs events from the KB vendedlogs group and logs ingestion job status (STARTING, IN_PROGRESS, COMPLETE, FAILED).
- **`lambda_semantic_rag_handler.py`** — Calls `bedrock-agent-runtime.retrieve_and_generate` with `overrideSearchType: SEMANTIC`. Input: `{"query": "..."}`.
- **`lambda_hybrid_rag_handler.py`** — Same as semantic but with `overrideSearchType: HYBRID`. Only works with OpenSearch Serverless-backed KBs, not S3 Vectors.

Terraform zips the lambda source files at plan/apply time using `archive_file` data sources; the `.zip` files are written to `lambdas/` and are gitignored.

### Key hardcoded value

`knowledge_base_id = "ZI2DHYWRGS"` is hardcoded in `terraform/main.tf` locals. This is used for the CloudWatch Logs subscription filter log group path and is passed as an env var to all Lambdas. Update this after `terraform apply` if the KB was recreated.

### Embedding model & chunking

- **Embeddings**: `amazon.titan-embed-text-v2:0` (1024 dimensions, cosine distance)
- **Chunking**: Semantic chunking — configurable via `max_tokens`, `buffer_size`, `breakpoint_percentile_threshold` variables
- **Generation model**: `anthropic.claude-3-5-sonnet-20241022-v2:0`

### Evaluation dataset format (JSONL)

Each line must be valid JSON with these fields:
```json
{"prompt": "...", "referenceResponse": "...", "category": "..."}
```
The `category` field is required by Bedrock evaluation jobs. The script auto-detects `LLM_JUDGE_BUCKET` and `EVALUATION_ROLE_ARN` from `terraform output` (run from `terraform/`) if not set as env vars.

## Configuration

Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` to override defaults. Resource names follow the pattern `${project_name}-${environment}-<resource>-${account_id}`.

## CI/CD (GitHub Actions)

`.github/workflows/terraform.yml` runs on every PR and push to `main`:

- **Pull request**: `terraform plan` output is posted as a PR comment (old bot comments are replaced)
- **Push to main**: `terraform apply` runs automatically using the saved plan

### Remote state

| Setting | Value |
|---------|-------|
| S3 bucket | `bedrock-rag-tfstate-741448928264` |
| State key | `bedrock-poc/terraform.tfstate` |
| Lock table | `bedrock-rag-tfstate-lock` (DynamoDB, PAY_PER_REQUEST) |
| Region | `us-east-1` |

Backend is configured in `terraform/providers.tf`. State was migrated from local with `terraform init -migrate-state`.

### Required GitHub Secrets

Add these in `Settings → Secrets and variables → Actions`:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user with Bedrock + S3 + Lambda permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |

`GITHUB_TOKEN` is automatically provided by GitHub — no action needed.

### Bootstrap script

`scripts/bootstrap-tf-backend.sh` creates the S3 bucket and DynamoDB table. **Already run for this repo — do not re-run** unless recreating from scratch in a new account.

### `terraform destroy` caveat

Destroy from CI is **unsafe**: `null_resource` provisioners write KB/DS IDs to `/tmp/*.txt`, which are ephemeral on GitHub-hosted runners. Always run `terraform destroy` locally, or pre-populate the ID files from AWS CLI before running destroy on a fresh machine.
