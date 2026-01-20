# -----------------------------------------------------------------------------
# LLM as a Judge Evaluations
# S3 bucket for storing evaluation datasets in JSONL format
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "llm_judge_evaluations" {
  bucket = "${local.resource_prefix}-llm-judge-${local.account_id}"

  tags = {
    Name    = "${local.resource_prefix}-llm-judge"
    Purpose = "LLM as a Judge evaluations"
  }
}

resource "aws_s3_bucket_versioning" "llm_judge_evaluations" {
  bucket = aws_s3_bucket.llm_judge_evaluations.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "llm_judge_evaluations" {
  bucket = aws_s3_bucket.llm_judge_evaluations.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "llm_judge_evaluations" {
  bucket = aws_s3_bucket.llm_judge_evaluations.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS configuration for the LLM Judge bucket
resource "aws_s3_bucket_cors_configuration" "llm_judge_evaluations" {
  bucket = aws_s3_bucket.llm_judge_evaluations.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag", "x-amz-meta-custom-header"]
    max_age_seconds = 3000
  }
}

# -----------------------------------------------------------------------------
# IAM Role for Bedrock Model Evaluation
# -----------------------------------------------------------------------------
resource "aws_iam_role" "bedrock_evaluation" {
  name = "${local.resource_prefix}-bedrock-evaluation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

# Policy for S3 access (read/write evaluation datasets and results)
resource "aws_iam_role_policy" "bedrock_evaluation_s3" {
  name = "${local.resource_prefix}-bedrock-evaluation-s3-policy"
  role = aws_iam_role.bedrock_evaluation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.llm_judge_evaluations.arn,
          "${aws_s3_bucket.llm_judge_evaluations.arn}/*"
        ]
      }
    ]
  })
}

# Policy for Bedrock model invocation (for judge model)
resource "aws_iam_role_policy" "bedrock_evaluation_model" {
  name = "${local.resource_prefix}-bedrock-evaluation-model-policy"
  role = aws_iam_role.bedrock_evaluation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:${local.region}::foundation-model/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:CreateEvaluationJob",
          "bedrock:GetEvaluationJob",
          "bedrock:ListEvaluationJobs",
          "bedrock:StopEvaluationJob"
        ]
        Resource = [
          "arn:aws:bedrock:${local.region}:${local.account_id}:evaluation-job/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs for LLM as a Judge
# -----------------------------------------------------------------------------
output "llm_judge_bucket_name" {
  description = "Name of the S3 bucket for LLM as a Judge evaluations"
  value       = aws_s3_bucket.llm_judge_evaluations.id
}

output "llm_judge_bucket_arn" {
  description = "ARN of the S3 bucket for LLM as a Judge evaluations"
  value       = aws_s3_bucket.llm_judge_evaluations.arn
}

output "llm_judge_evaluation_role_arn" {
  description = "ARN of the IAM role for Bedrock evaluations"
  value       = aws_iam_role.bedrock_evaluation.arn
}

output "llm_judge_example_jsonl_format" {
  description = "Example JSONL format for evaluation dataset"
  value       = <<-EOT
    {"prompt": "What is the capital of France?", "referenceResponse": "Paris is the capital of France.", "category": "geography"}
    {"prompt": "Explain photosynthesis", "referenceResponse": "Photosynthesis is the process by which plants convert sunlight into energy.", "category": "science"}
  EOT
}

output "llm_judge_create_evaluation_command" {
  description = "Example command to create an LLM as a Judge evaluation job"
  value       = <<-EOT
    aws bedrock create-evaluation-job \
      --job-name "my-evaluation-job" \
      --role-arn "${aws_iam_role.bedrock_evaluation.arn}" \
      --evaluation-config '{
        "automated": {
          "datasetMetricConfigs": [{
            "taskType": "General",
            "dataset": {
              "name": "my-dataset",
              "datasetLocation": {
                "s3Uri": "s3://${aws_s3_bucket.llm_judge_evaluations.id}/datasets/eval-dataset.jsonl"
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
        "s3Uri": "s3://${aws_s3_bucket.llm_judge_evaluations.id}/results/"
      }' \
      --region ${local.region}
  EOT
}
