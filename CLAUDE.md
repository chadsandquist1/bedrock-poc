# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Terraform-managed AWS proof-of-concept for a RAG (Retrieval-Augmented Generation) pipeline using AWS Bedrock Knowledge Base with S3 Vectors as the vector store. It includes document indexing with filename metadata, inline citation Lambdas, and an LLM-as-a-Judge evaluation framework.

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

### Post-deploy: upload docs and index metadata

```bash
# 1. Upload sample documents
aws s3 sync scripts/documents/ s3://$(cd terraform && terraform output -raw documents_bucket_name)/

# 2. Run the document indexer Lambda — generates document-index.txt, per-file
#    .metadata.json files, and starts a Bedrock ingestion job automatically
aws lambda invoke --function-name bedrock-rag-dev-document-indexer --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout
```

The document indexer replaces the manual ingestion workflow. There is no need to call `start-ingestion-job` separately.

### Invoke RAG Lambdas

```bash
# Inline citations via Retrieve + Converse Citations API (recommended, S3 Vectors compatible)
aws lambda invoke --function-name bedrock-rag-dev-rag-citations-v2 --payload '{"query": "What is photosynthesis?"}' --cli-binary-format raw-in-base64-out /dev/stdout

# Inline citations via RetrieveAndGenerate + span post-processing
aws lambda invoke --function-name bedrock-rag-dev-rag-citations-v1 --payload '{"query": "What is photosynthesis?"}' --cli-binary-format raw-in-base64-out /dev/stdout

# Hybrid search (requires OpenSearch Serverless KB, not S3 Vectors — errors at runtime)
aws lambda invoke --function-name bedrock-rag-dev-hybrid-rag --payload '{"query": "What is photosynthesis?"}' --cli-binary-format raw-in-base64-out /dev/stdout
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

## Repository Structure

```
bedrock-poc/
├── .github/
│   └── workflows/
│       └── terraform.yml           # CI/CD: plan on PR, apply on merge to main
├── .pre-commit-config.yaml         # Pre-commit hooks: ruff, terraform_fmt, shellcheck, etc.
├── terraform/                      # All Terraform configuration
│   ├── main.tf                     # S3 buckets, IAM, S3 Vectors, Knowledge Base, Data Source
│   ├── lambda_rag.tf               # Hybrid RAG test Lambda
│   ├── lambda_citations.tf         # V1 and V2 inline citation Lambdas
│   ├── lambda_indexer.tf           # Document indexer Lambda
│   ├── llmasjudge.tf               # S3 bucket + IAM role for LLM-as-a-Judge evaluations
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── terraform.tfvars.example
├── lambdas/                        # Lambda handler source code
│   ├── lambda_hybrid_rag_handler.py
│   ├── lambda_rag_citations_v1_handler.py
│   ├── lambda_rag_citations_v2_handler.py
│   ├── lambda_document_indexer_handler.py
│   └── CITATIONS_README.md
└── scripts/                        # Operational scripts and sample data
    ├── bootstrap-tf-backend.sh     # One-time S3 + DynamoDB backend setup (already run)
    ├── llm_judge_evaluation.py
    ├── requirements.txt
    ├── sample-evaluation-dataset.jsonl
    └── documents/                  # Sample RAG source documents
```

## Architecture

### Why `null_resource` for core resources?

S3 Vectors and Bedrock Knowledge Base with `S3_VECTORS` storage type are not fully supported by the Terraform AWS provider. These resources are created/destroyed via `local-exec` provisioners calling the AWS CLI directly. IDs are persisted to `/tmp/kb_id_<name>.txt` and `/tmp/ds_id_<name>.txt` for use during destroy.

### Lambda functions (all Python 3.11, source in `lambdas/`)

- **`lambda_document_indexer_handler.py`** — Lists all `.txt` files in the documents bucket, tokenizes each filename into keywords, writes `document-index.txt` (natural-language sentences for vector search) and `<file>.metadata.json` (Bedrock metadata attributes) back to S3, then starts a Bedrock ingestion job. Run this after uploading new documents. Input: `{}`.

- **`lambda_rag_citations_v2_handler.py`** *(recommended)* — Two-step: `retrieve()` fetches KB chunks (filename read from chunk metadata), then `converse()` with `DocumentBlock`s and `citationsConfig: {enabled: true}`. Uses a pre-built `{doc_name: chunk}` dict for exact citation-to-source resolution — no heuristic URI matching. Input: `{"query": "..."}`. Output: `html_response` with inline `<sup>[N]</sup>` tags, `references[]` showing filenames.

- **`lambda_rag_citations_v1_handler.py`** — Single call to `retrieve_and_generate` (SEMANTIC, S3 Vectors compatible). Post-processes span offsets to insert `<sup>` markers end→start. Lower latency but no prompt control. Input: `{"query": "..."}`.

- **`lambda_hybrid_rag_handler.py`** — Calls `retrieve_and_generate` with `overrideSearchType: HYBRID`. **Only works with OpenSearch Serverless-backed KBs, not S3 Vectors.** Input: `{"query": "..."}`.

Terraform zips the lambda source files at plan/apply time using `archive_file` data sources; the `.zip` files are written to `lambdas/` and are gitignored.

### Document metadata

The document indexer writes two artifacts per source file to the documents S3 bucket:

1. **`<file>.metadata.json`** — Bedrock reads this alongside the source doc during ingestion and attaches the attributes to every vector chunk:
   ```json
   {
     "metadataAttributes": {
       "filename":        {"value": {"stringValue": "france-geography.txt"}, "type": "STRING"},
       "filename_tokens": {"value": {"stringValue": "france geography"},     "type": "STRING"},
       "topic_france":    {"value": {"stringValue": "france"},               "type": "STRING"},
       "topic_geography": {"value": {"stringValue": "geography"},            "type": "STRING"}
     }
   }
   ```

2. **`document-index.txt`** — Plain-text index ingested into the KB so natural-language queries like *"find filenames with geography in the title"* return `france-geography.txt` via vector search:
   ```
   The file france-geography.txt covers topics including: france, geography.
   ```

The V2 citation Lambda reads `filename` from chunk metadata returned by `retrieve()`, eliminating the need for URI parsing or heuristic title-to-source matching.

### Key hardcoded values

Both are in `terraform/main.tf` locals — update after `terraform apply` if resources are recreated:

- `knowledge_base_id = "ZI2DHYWRGS"`
- `data_source_id = "IZP4FOAXOO"`

### Embedding model & chunking

- **Embeddings**: `amazon.titan-embed-text-v2:0` (1024 dimensions, cosine distance)
- **Chunking**: Semantic chunking — configurable via `max_tokens`, `buffer_size`, `breakpoint_percentile_threshold` variables
- **Generation model**: `anthropic.claude-sonnet-4-6`

### Evaluation dataset format (JSONL)

Each line must be valid JSON with these fields:
```json
{"prompt": "...", "referenceResponse": "...", "category": "..."}
```
The `category` field is required by Bedrock evaluation jobs. The script auto-detects `LLM_JUDGE_BUCKET` and `EVALUATION_ROLE_ARN` from `terraform output` (run from `terraform/`) if not set as env vars.

## Configuration

Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars` to override defaults. Resource names follow the pattern `${project_name}-${environment}-<resource>-${account_id}`.

## Pre-commit Hooks

`.pre-commit-config.yaml` runs on every `git commit`. Install once per machine:

```bash
pip install pre-commit
pre-commit install
```

Run against all files manually:

```bash
pre-commit run --all-files
```

| Hook | Source | What it does |
|------|--------|-------------|
| `trailing-whitespace` | pre-commit-hooks | Removes trailing whitespace |
| `end-of-file-fixer` | pre-commit-hooks | Ensures files end with a newline |
| `check-yaml` | pre-commit-hooks | Validates YAML syntax |
| `check-json` | pre-commit-hooks | Validates JSON syntax |
| `check-merge-conflict` | pre-commit-hooks | Blocks accidental conflict markers |
| `ruff` | astral-sh/ruff-pre-commit | Python lint + auto-fix |
| `ruff-format` | astral-sh/ruff-pre-commit | Python formatting |
| `terraform_fmt` | antonbabenko/pre-commit-terraform | Terraform formatting |
| `shellcheck` | shellcheck-py | Shell script linting |

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
