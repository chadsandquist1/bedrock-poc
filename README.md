# Bedrock RAG Pipeline with S3 Vectors

A simplified RAG (Retrieval-Augmented Generation) pipeline using AWS Bedrock Knowledge Base with S3 Vectors store and semantic chunking.

## Architecture

- **Document Storage**: S3 bucket for source documents
- **Vector Store**: S3 Vectors (created via AWS CLI null_resource)
- **Embeddings**: Amazon Titan Embeddings V2 (cheapest option, 1024 dimensions)
- **Chunking**: Semantic chunking for intelligent document segmentation
- **Knowledge Base**: AWS Bedrock Knowledge Base (created via AWS CLI null_resource)
- **LLM as a Judge**: S3 bucket for evaluation datasets (JSONL) with CORS enabled

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

## Next Steps: LLM as a Judge Evaluations

After deploying your RAG pipeline, you can evaluate your model's responses using **LLM as a Judge**. This feature uses a foundation model to automatically assess the quality of responses.

### What is LLM as a Judge?

LLM as a Judge is an automated evaluation method where a large language model evaluates the outputs of another model based on criteria like:
- **Accuracy**: How factually correct are the responses?
- **Relevance**: How well do responses address the prompt?
- **Coherence**: How logically structured are the responses?
- **Helpfulness**: How useful are the responses to the user?

### Resources Created

The `llmasjudge.tf` file creates:
- **S3 Bucket**: `bedrock-rag-dev-llm-judge-<account-id>` with CORS enabled for JSONL datasets
- **IAM Role**: For Bedrock evaluation jobs with S3 and model invocation permissions

### Preparing Your Evaluation Dataset

Create a JSONL file with your evaluation data. Each line should be a valid JSON object:

```jsonl
{"prompt": "What is the capital of France?", "referenceResponse": "Paris is the capital of France.", "category": "geography"}
{"prompt": "Explain photosynthesis briefly", "referenceResponse": "Photosynthesis is the process by which plants convert sunlight, water, and CO2 into glucose and oxygen.", "category": "science"}
{"prompt": "What are the benefits of exercise?", "referenceResponse": "Exercise improves cardiovascular health, mental well-being, and helps maintain a healthy weight.", "category": "health"}
```

### Upload Your Dataset

```bash
# Get the LLM Judge bucket name
LLM_JUDGE_BUCKET=$(terraform output -raw llm_judge_bucket_name)

# Upload your evaluation dataset
aws s3 cp evaluation-dataset.jsonl s3://$LLM_JUDGE_BUCKET/datasets/
```

### Create an Evaluation Job

```bash
# Get the evaluation role ARN
EVAL_ROLE_ARN=$(terraform output -raw llm_judge_evaluation_role_arn)
LLM_JUDGE_BUCKET=$(terraform output -raw llm_judge_bucket_name)

# Create the evaluation job
aws bedrock create-evaluation-job \
  --job-name "rag-evaluation-$(date +%Y%m%d-%H%M%S)" \
  --role-arn "$EVAL_ROLE_ARN" \
  --evaluation-config '{
    "automated": {
      "datasetMetricConfigs": [{
        "taskType": "General",
        "dataset": {
          "name": "rag-eval-dataset",
          "datasetLocation": {
            "s3Uri": "s3://'"$LLM_JUDGE_BUCKET"'/datasets/evaluation-dataset.jsonl"
          }
        },
        "metricNames": ["Builtin.Accuracy", "Builtin.Robustness"]
      }]
    }
  }' \
  --inference-config '{
    "models": [{
      "bedrockModel": {
        "modelIdentifier": "amazon.titan-text-lite-v1",
        "inferenceParams": "{\"maxTokenCount\": 512, \"temperature\": 0}"
      }
    }]
  }' \
  --output-data-config '{
    "s3Uri": "s3://'"$LLM_JUDGE_BUCKET"'/results/"
  }' \
  --region us-east-1
```

### Monitor Your Evaluation Job

```bash
# List all evaluation jobs
aws bedrock list-evaluation-jobs --region us-east-1

# Get details of a specific job
aws bedrock get-evaluation-job --job-identifier <job-arn> --region us-east-1
```

### Retrieve Results

Once the job completes, results are stored in the S3 bucket:

```bash
# Download results
aws s3 sync s3://$LLM_JUDGE_BUCKET/results/ ./evaluation-results/
```

### Evaluation Metrics

Available built-in metrics include:
| Metric | Description |
|--------|-------------|
| `Builtin.Accuracy` | Measures factual correctness |
| `Builtin.Robustness` | Measures consistency across similar prompts |
| `Builtin.Toxicity` | Detects harmful or inappropriate content |

### Integration with RAG Pipeline

To evaluate your RAG pipeline's responses:

1. Query your Knowledge Base and collect responses
2. Format responses into JSONL with prompts and reference answers
3. Upload to the LLM Judge bucket
4. Run an evaluation job
5. Analyze results to identify areas for improvement

### Cost Considerations

- Evaluation jobs incur costs for model invocations (judge model)
- S3 storage costs for datasets and results
- Use `amazon.titan-text-lite-v1` as the judge model for cost-effective evaluations
