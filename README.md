# Bedrock RAG Pipeline with S3 Vectors

A simplified RAG (Retrieval-Augmented Generation) pipeline using AWS Bedrock Knowledge Base with S3 Vectors store and semantic chunking.

## Architecture

- **Document Storage**: S3 bucket for source documents
- **Vector Store**: S3 Vectors (created via AWS CLI null_resource)
- **Embeddings**: Amazon Titan Embeddings V2 (cheapest option, 1024 dimensions)
- **Chunking**: Semantic chunking for intelligent document segmentation
- **Knowledge Base**: AWS Bedrock Knowledge Base (created via AWS CLI null_resource)
- **LLM as a Judge**: S3 bucket for evaluation datasets (JSONL) with CORS enabled

## Project Structure

```
bedrock-poc/
├── main.tf                 # Main Terraform configuration (S3, IAM, Knowledge Base)
├── llmasjudge.tf           # LLM as a Judge evaluation resources
├── variables.tf            # Input variables
├── outputs.tf              # Output values
├── providers.tf            # Provider configuration
├── terraform.tfvars.example # Example variables file
├── README.md
└── scripts/
    ├── llm_judge_evaluation.py      # Python evaluation script
    ├── requirements.txt             # Python dependencies
    ├── sample-evaluation-dataset.jsonl  # Sample JSONL dataset
    └── documents/                   # Sample documents for RAG
        ├── france-geography.txt
        ├── rag-ai-explanation.txt
        ├── photosynthesis-biology.txt
        ├── states-of-matter.txt
        └── shakespeare-literature.txt
```

## Prerequisites

- AWS CLI v2.30+ (with S3 Vectors support)
- Terraform >= 1.0
- Python 3.8+ with pip
- `jq` installed for JSON parsing
- AWS credentials configured with appropriate permissions
- Access to Amazon Bedrock (request access in AWS Console)

## Quick Start

```bash
# 1. Deploy infrastructure
terraform init
terraform apply

# 2. Upload sample documents to RAG
aws s3 sync scripts/documents/ s3://$(terraform output -raw documents_bucket_name)/

# 3. Start ingestion
KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 | jq -r '.knowledgeBaseSummaries[] | select(.name=="bedrock-rag-dev-knowledge-base") | .knowledgeBaseId')
DS_ID=$(aws bedrock-agent list-data-sources --knowledge-base-id $KB_ID --region us-east-1 | jq -r '.dataSourceSummaries[0].dataSourceId')
aws bedrock-agent start-ingestion-job --knowledge-base-id $KB_ID --data-source-id $DS_ID --region us-east-1

# 4. Run LLM evaluation (after ingestion completes)
cd scripts
pip install -r requirements.txt
python llm_judge_evaluation.py --dataset sample-evaluation-dataset.jsonl
```

## Detailed Usage

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
# Upload sample documents
aws s3 sync scripts/documents/ s3://$(terraform output -raw documents_bucket_name)/

# Or upload your own documents
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
  --data-type float32 \
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

---

## LLM as a Judge Evaluations

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

### JSONL Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `prompt` | Yes | The input question or prompt to evaluate |
| `referenceResponse` | Yes | The expected/ideal response for comparison |
| `category` | Yes | Category label for grouping and filtering results |

#### Why is `category` required?

The `category` field is **required by AWS Bedrock evaluation jobs** for:

1. **Results Grouping**: Allows you to analyze performance across different topic areas (e.g., "geography" vs "science")
2. **Filtering**: Filter evaluation results by category to identify weak areas
3. **Reporting**: Generate category-specific accuracy reports
4. **Benchmarking**: Compare model performance across different domains

You can use any string value for category - common examples:
- Topic-based: `"geography"`, `"science"`, `"history"`, `"coding"`
- Difficulty-based: `"easy"`, `"medium"`, `"hard"`
- Source-based: `"faq"`, `"documentation"`, `"user-generated"`

---

## Python Evaluation Script

A Python script (`scripts/llm_judge_evaluation.py`) automates the entire evaluation workflow.

### Installation

```bash
cd scripts
pip install -r requirements.txt
```

### Basic Usage

```bash
# Run evaluation with the sample dataset
python llm_judge_evaluation.py --dataset sample-evaluation-dataset.jsonl

# Run with your own dataset
python llm_judge_evaluation.py --dataset /path/to/your-eval.jsonl
```

### Command-Line Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--dataset` | `-d` | - | Path to local JSONL evaluation dataset |
| `--job-name` | `-n` | auto-generated | Name for the evaluation job |
| `--model` | `-m` | amazon.nova-2-sonic-v1:0 | Model ID to evaluate |
| `--task-type` | - | QuestionAndAnswer | Task type (see below) |
| `--metrics` | - | Builtin.Accuracy Builtin.Robustness | Metrics to evaluate |
| `--timeout` | `-t` | 1800 | Timeout in seconds for monitoring |
| `--output-dir` | `-o` | ./evaluation-results/<job-name> | Directory for results |
| `--region` | - | us-east-1 | AWS region |

### Valid Task Types

| Task Type | Use Case |
|-----------|----------|
| `QuestionAndAnswer` | RAG, Q&A systems (default) |
| `Summarization` | Text summarization tasks |
| `Classification` | Text classification tasks |
| `Generation` | General text generation |
| `Custom` | Custom evaluation criteria |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `EVALUATION_JOB_ARN` | ARN of existing job to monitor (skips creation) |
| `LLM_JUDGE_BUCKET` | S3 bucket name (auto-detected from Terraform) |
| `EVALUATION_ROLE_ARN` | IAM role ARN (auto-detected from Terraform) |
| `AWS_REGION` | AWS region (default: us-east-1) |

### Examples

```bash
# Basic evaluation with sample data
python llm_judge_evaluation.py --dataset sample-evaluation-dataset.jsonl

# Custom job name and task type
python llm_judge_evaluation.py \
  --dataset eval.jsonl \
  --job-name my-rag-evaluation \
  --task-type QuestionAndAnswer

# Use a different model
python llm_judge_evaluation.py \
  --dataset eval.jsonl \
  --model amazon.nova-2-sonic-v1:0

# Monitor an existing job
export EVALUATION_JOB_ARN='arn:aws:bedrock:us-east-1:123456789:evaluation-job/abc123'
python llm_judge_evaluation.py

# Specify custom output directory
python llm_judge_evaluation.py \
  --dataset eval.jsonl \
  --output-dir ./my-results
```

### Script Workflow

1. **Upload**: Validates and uploads JSONL dataset to S3
2. **Create**: Creates a Bedrock evaluation job
3. **Monitor**: Polls job status until completion (with timeout)
4. **Download**: Downloads results to local directory

---

## Manual Evaluation Method

If you prefer not to use the Python script:

### Upload Your Dataset

```bash
LLM_JUDGE_BUCKET=$(terraform output -raw llm_judge_bucket_name)
aws s3 cp evaluation-dataset.jsonl s3://$LLM_JUDGE_BUCKET/datasets/
```

### Create an Evaluation Job

```bash
EVAL_ROLE_ARN=$(terraform output -raw llm_judge_evaluation_role_arn)
LLM_JUDGE_BUCKET=$(terraform output -raw llm_judge_bucket_name)

aws bedrock create-evaluation-job \
  --job-name "rag-evaluation-$(date +%Y%m%d-%H%M%S)" \
  --role-arn "$EVAL_ROLE_ARN" \
  --evaluation-config '{
    "automated": {
      "datasetMetricConfigs": [{
        "taskType": "QuestionAndAnswer",
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
        "modelIdentifier": "amazon.nova-2-sonic-v1:0",
        "inferenceParams": "{\"maxTokens\": 512, \"temperature\": 0.7, \"topP\": 0.9}"
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

```bash
aws s3 sync s3://$LLM_JUDGE_BUCKET/results/ ./evaluation-results/
```

---

## Evaluation Metrics

### Available metricNames Options

When creating an evaluation job, you can specify which metrics to evaluate using the `--metrics` flag or `metricNames` in the API. Available options:

| Metric Name | Task Types | Description |
|-------------|------------|-------------|
| `Builtin.Accuracy` | QuestionAndAnswer, Generation | Measures text similarity between model response and reference response |
| `Builtin.Robustness` | QuestionAndAnswer, Generation | Measures response consistency, coherence, and semantic quality |
| `Builtin.Toxicity` | All | Detects harmful, offensive, or inappropriate content |
| `Builtin.Correctness` | QuestionAndAnswer | Evaluates factual correctness of responses |
| `Builtin.Completeness` | Summarization | Measures how completely the summary covers key points |
| `Builtin.Relevance` | QuestionAndAnswer, Summarization | Evaluates how relevant the response is to the prompt |
| `Builtin.Faithfulness` | Summarization | Measures if summary is faithful to source without hallucination |

### Using Multiple Metrics

```bash
# Specify multiple metrics
python llm_judge_evaluation.py \
  --dataset eval.jsonl \
  --metrics Builtin.Accuracy Builtin.Robustness Builtin.Toxicity
```

### Default Metrics

The script defaults to `Builtin.Accuracy` and `Builtin.Robustness` which are suitable for most QuestionAndAnswer evaluations.

### Understanding the Metrics

#### Builtin.Accuracy
**What it measures**: Lexical similarity between the model's response and the reference response using metrics like BLEU, ROUGE, or similar text comparison algorithms.

**Score range**: 0.0 to 1.0 (higher is better)

**Important notes**:
- Scores are typically **low (0.15-0.30)** when the model provides detailed responses compared to short reference answers
- A low accuracy score does NOT mean the answer is wrong - it means the text differs from the reference
- Example: If the reference is "Paris is the capital of France" but the model responds with a detailed paragraph about Paris, the accuracy score will be low despite being correct

#### Builtin.Robustness
**What it measures**: Semantic consistency and coherence of the model's response. This evaluates how well-structured, complete, and contextually appropriate the response is.

**Score range**: 0.0 to 100.0 (higher indicates more robust/complete responses)

**Important notes**:
- Higher scores indicate more comprehensive, well-structured responses
- Measures factors like completeness, coherence, and semantic richness
- A response with more context and explanation typically scores higher

---

## Example Evaluation Results

The following are **example results** from running the evaluation script with `amazon.nova-lite-v1:0` model against the sample dataset:

### Summary Table

| Prompt | Accuracy | Robustness | Notes |
|--------|----------|------------|-------|
| What is the capital of France? | 0.20 | 17.88 | Model provided detailed response vs short reference |
| Explain what RAG stands for in AI | 0.23 | 43.29 | Comprehensive explanation scored higher robustness |
| What is photosynthesis? | 0.17 | 38.69 | Detailed scientific explanation |
| What are the three states of matter? | 0.21 | 44.85 | Included additional context about plasma |
| Who wrote Romeo and Juliet? | 0.17 | 18.45 | Added historical context |

### Example Output (JSONL format)

Each result in the output file contains:

```json
{
  "automatedEvaluationResult": {
    "scores": [
      {"metricName": "Builtin.Accuracy", "result": 0.196},
      {"metricName": "Builtin.Robustness", "result": 17.878}
    ]
  },
  "inputRecord": {
    "prompt": "What is the capital of France?",
    "referenceResponse": "Paris is the capital of France.",
    "category": "geography"
  },
  "modelResponses": [
    {
      "response": "The capital of France is Paris. Paris is not only the capital but also the largest city in France, known for its significant historical, cultural, and artistic contributions...",
      "modelIdentifier": "amazon.nova-lite-v1:0",
      "stopReason": "end_turn"
    }
  ]
}
```

### Interpreting Results

- **Low Accuracy + High Robustness**: Model provided correct but verbose answers (common with capable models)
- **High Accuracy + Low Robustness**: Model closely matched reference but may lack depth
- **Low Accuracy + Low Robustness**: May indicate issues with response quality

For RAG evaluations, focus on **Robustness** for response quality and manually verify factual correctness, as Accuracy primarily measures text similarity rather than semantic correctness.

---

## Cost Considerations

- Evaluation jobs incur costs for model invocations (judge model)
- S3 storage costs for datasets and results
- Use `amazon.nova-2-sonic-v1:0` as the judge model for cost-effective evaluations

## Security Notes

The `.gitignore` is configured to exclude:
- Terraform state files (`*.tfstate`, `*.tfstate.*`)
- AWS credentials and keys (`*.pem`, `*.key`, `credentials`)
- Environment files (`.env`, `*.tfvars`)
- Evaluation results (may contain sensitive data)
- Python cache files

**Never commit:**
- AWS access keys or secrets
- Terraform state files
- `.env` files with credentials
