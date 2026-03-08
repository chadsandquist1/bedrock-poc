# Plan: Filename-Based Document Indexing for Bedrock RAG

## Context

The Bedrock RAG knowledge base can retrieve document *content* via vector search but has no mechanism to answer meta-queries like "find filenames that have the word geography in the title". The S3 source documents have no metadata files, so citations only return the full S3 URI. The goal is to allow natural language queries about filenames to return the matching filename (e.g., `france-geography.txt`).

**Chosen approach**: Create a new on-demand Lambda that generates:
1. A `document-index.txt` — plain-text file listing all filenames + their tokenized keywords in natural-language sentences. Ingested into the KB so vector search can find it.
2. Per-file `.metadata.json` — enables future programmatic metadata filtering.

After uploading both, the Lambda auto-triggers a Bedrock ingestion job.

## Files to Create

- `lambdas/lambda_document_indexer_handler.py` — new Lambda handler
- `terraform/lambda_indexer.tf` — Terraform for the new Lambda + IAM + CloudWatch

## Files to Modify

- `terraform/main.tf` — add `data_source_id` local (line 11, after `knowledge_base_id`)

---

## Implementation Details

### 1. Edit `terraform/main.tf` — add `data_source_id` local

In the `locals` block (line 5–11), add after `knowledge_base_id`:
```hcl
  data_source_id     = "PLACEHOLDER" # Hardcoded DS ID; update after apply
```

Get the real value with:
```bash
aws bedrock-agent list-data-sources \
  --knowledge-base-id ZI2DHYWRGS --region us-east-1 \
  | jq -r '.dataSourceSummaries[0].dataSourceId'
```

### 2. `lambdas/lambda_document_indexer_handler.py`

Lambda logic:
- `list_source_documents()` — paginates `list_objects_v2`, returns all `.txt` keys excluding `document-index.txt` and `.metadata.json` files
- `tokenize_filename(name)` — splits on `-`, `_`, `.`; lowercases; drops extension token
- `build_index_content(keys)` — builds plain-text file, one sentence per doc:
  ```
  The file france-geography.txt covers topics including: france, geography.
  ```
- `build_metadata(filename)` — Bedrock-compatible structure:
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
- Uploads `document-index.txt` and `<key>.metadata.json` files to the documents bucket
- Calls `bedrock_agent.start_ingestion_job(knowledgeBaseId=..., dataSourceId=...)`
- Returns JSON summary with `files_indexed`, `metadata_files_created`, `ingestion_job_id`, `latency_ms`

Env vars: `DOCUMENTS_BUCKET`, `KNOWLEDGE_BASE_ID`, `DATA_SOURCE_ID`

### 3. `terraform/lambda_indexer.tf`

Resources to create:
- `data "archive_file" "document_indexer_zip"` — zips `lambda_document_indexer_handler.py`
- `aws_iam_role.document_indexer_lambda` — trust: `lambda.amazonaws.com`
- `aws_iam_role_policy.document_indexer_s3` — `s3:ListBucket` on bucket ARN, `s3:GetObject` + `s3:PutObject` on `bucket/*`
- `aws_iam_role_policy.document_indexer_bedrock` — `bedrock:StartIngestionJob` on `local.rag_kb_arn`
- `aws_iam_role_policy.document_indexer_logging` — CloudWatch logs on `/aws/lambda/${local.resource_prefix}-document-indexer:*`
- `aws_lambda_function.document_indexer` — Python 3.11, 120s timeout, 256MB, env vars
- `aws_cloudwatch_log_group.document_indexer_logs` — 14-day retention
- Outputs: `document_indexer_lambda_name`, `invoke_document_indexer_command`

References `local.resource_prefix`, `local.rag_kb_arn` (defined in `lambda_rag.tf`), and `aws_s3_bucket.documents`.

---

## Verification

### Step 1 — Get DS ID and update main.tf
```bash
aws bedrock-agent list-data-sources --knowledge-base-id ZI2DHYWRGS --region us-east-1 \
  | jq -r '.dataSourceSummaries[0].dataSourceId'
# Update terraform/main.tf: data_source_id = "<value>"
```

### Step 2 — Deploy
```bash
cd terraform && terraform apply
```

### Step 3 — Invoke Lambda
```bash
FUNC=$(terraform output -raw document_indexer_lambda_name)
aws lambda invoke --function-name "$FUNC" --payload '{}' \
  --cli-binary-format raw-in-base64-out /dev/stdout
```

### Step 4 — Verify S3 contents
```bash
BUCKET=$(terraform output -raw documents_bucket_name)
aws s3 ls s3://$BUCKET/
# Expect: 5 .txt, document-index.txt, 5 .metadata.json files
```

### Step 5 — Monitor ingestion
```bash
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id ZI2DHYWRGS \
  --data-source-id <DS_ID> \
  --ingestion-job-id <job-id> \
  --region us-east-1
# Wait for status: COMPLETE
```

### Step 6 — Test the query
Invoke one of the existing citation Lambdas (V1 or V2) with:
```json
{"query": "Find me the filenames that have the word geography in the title"}
```
Expected: response includes `france-geography.txt` sourced from `document-index.txt`.
