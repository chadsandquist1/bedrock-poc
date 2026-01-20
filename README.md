# Bedrock RAG Pipeline with S3 Vectors

A simplified RAG (Retrieval-Augmented Generation) pipeline using AWS Bedrock Knowledge Base with S3 Vectors store and semantic chunking.

## Architecture

- **Document Storage**: S3 bucket for source documents
- **Vector Store**: S3 Vectors (created via AWS CLI null_resource)
- **Embeddings**: Amazon Titan Embeddings V2 (cheapest option, 1024 dimensions)
- **Chunking**: Semantic chunking for intelligent document segmentation
- **Knowledge Base**: AWS Bedrock Knowledge Base (created via AWS CLI null_resource)

## Prerequisites

- AWS CLI v2 with S3 Vectors support
- Terraform >= 1.0
- `jq` installed for JSON parsing
- AWS credentials configured with appropriate permissions
- Access to Amazon Bedrock (request access in AWS Console)

## Usage

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Review the plan

```bash
terraform plan
```

### 3. Apply the configuration

```bash
terraform apply
```

### 4. Get the Knowledge Base ID

```bash
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 | \
  jq -r '.knowledgeBaseSummaries[] | select(.name=="bedrock-rag-dev-knowledge-base") | .knowledgeBaseId')
echo $KB_ID
```

### 5. Get the Data Source ID

```bash
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --region us-east-1 | \
  jq -r '.dataSourceSummaries[0].dataSourceId')
echo $DS_ID
```

### 6. Upload documents to the S3 bucket

```bash
aws s3 cp your-document.pdf s3://$(terraform output -raw documents_bucket_name)/
```

### 7. Sync the Knowledge Base (start ingestion)

```bash
aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID \
  --region us-east-1
```

## Configuration

Key variables in `variables.tf`:

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | us-east-1 | AWS region |
| `vector_bucket_name` | rag-vector-store | S3 vector bucket name |
| `embedding_dimension` | 1024 | Titan Embeddings V2 dimension |
| `max_tokens` | 300 | Max tokens per chunk |
| `buffer_size` | 1 | Semantic chunking buffer |
| `breakpoint_percentile_threshold` | 95 | Semantic breakpoint threshold |

## Semantic Chunking

This pipeline uses semantic chunking which intelligently splits documents based on meaning rather than fixed token counts:

- **buffer_size**: Number of sentences to consider for boundary detection
- **max_tokens**: Maximum tokens per chunk
- **breakpoint_percentile_threshold**: Sensitivity for detecting topic changes (higher = fewer breaks)

## Resource Details

### S3 Vectors Commands Used

```bash
# Create vector bucket
aws s3vectors create-vector-bucket --vector-bucket-name "your-vector-bucket-name"

# Create vector index
aws s3vectors create-index \
  --vector-bucket-name my-vector-bucket \
  --index-name kb-index \
  --dimension 1024 \
  --distance-metric cosine
```

### Null Resources

The following resources are created via AWS CLI (null_resource) since Terraform AWS provider may not fully support S3 Vectors storage type yet:

1. **S3 Vector Bucket** - Vector storage bucket
2. **S3 Vector Index** - Index for vector similarity search
3. **Bedrock Knowledge Base** - Knowledge base with S3 Vectors storage
4. **Bedrock Data Source** - Document source with semantic chunking

## Costs

This configuration uses the most cost-effective options:

- **Titan Embeddings V2**: ~$0.00002 per 1K tokens (cheapest embedding model)
- **S3 Vectors**: Pay-per-use vector storage
- **S3 Standard**: Standard storage rates for documents

## Cleanup

```bash
terraform destroy
```

The null_resources include destroy provisioners to clean up:
- S3 vector bucket and index
- Bedrock Knowledge Base and Data Source

## Troubleshooting

### Knowledge Base not created
If the Knowledge Base creation fails, check:
1. IAM role has propagated (wait 30 seconds)
2. S3 Vectors bucket and index exist
3. Bedrock access is enabled in your account

### Vector bucket already exists
The `|| true` in the null_resource commands prevents errors if resources already exist. To recreate, first destroy:
```bash
terraform destroy
terraform apply
```
