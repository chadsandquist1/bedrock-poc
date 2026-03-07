# -----------------------------------------------------------------------------
# RAG Test Lambda — Hybrid Search
#
# NOTE: Hybrid search requires the knowledge base vector store to support
# full-text (BM25) search (e.g. OpenSearch Serverless). If you are using
# S3 Vectors, the hybrid lambda will return an error at runtime because
# S3 Vectors is a pure vector store.
# -----------------------------------------------------------------------------

locals {
  claude_model_id  = "us.anthropic.claude-3-5-sonnet-20241022-v2:0"
  claude_model_arn = "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/${local.claude_model_id}"
  rag_kb_id        = local.knowledge_base_id
  rag_kb_arn       = "arn:aws:bedrock:${local.region}:${local.account_id}:knowledge-base/${local.rag_kb_id}"
}

# -----------------------------------------------------------------------------
# Zip archive
# -----------------------------------------------------------------------------
data "archive_file" "hybrid_rag_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/lambda_hybrid_rag_handler.py"
  output_path = "${path.module}/../lambdas/lambda_hybrid_rag_handler.zip"
}

# -----------------------------------------------------------------------------
# IAM role for hybrid RAG lambda
# -----------------------------------------------------------------------------
resource "aws_iam_role" "rag_test_lambda" {
  name = "${local.resource_prefix}-rag-test-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
      }
    ]
  })

  tags = {
    Name    = "${local.resource_prefix}-rag-test-lambda-role"
    Purpose = "Execution role for hybrid RAG test lambda"
  }
}

resource "aws_iam_role_policy" "rag_test_bedrock" {
  name = "${local.resource_prefix}-rag-test-bedrock"
  role = aws_iam_role.rag_test_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:RetrieveAndGenerate",
          "bedrock:Retrieve",
        ]
        Resource = local.rag_kb_arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:GetInferenceProfile",
        ]
        Resource = local.claude_model_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "rag_test_logging" {
  name = "${local.resource_prefix}-rag-test-logging"
  role = aws_iam_role.rag_test_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.resource_prefix}-hybrid-rag:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Hybrid RAG Lambda
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "hybrid_rag" {
  filename         = data.archive_file.hybrid_rag_zip.output_path
  function_name    = "${local.resource_prefix}-hybrid-rag"
  role             = aws_iam_role.rag_test_lambda.arn
  handler          = "lambda_hybrid_rag_handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.hybrid_rag_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = local.rag_kb_id
      MODEL_ARN         = local.claude_model_arn
      NUMBER_OF_RESULTS = "5"
    }
  }

  tags = {
    Name       = "${local.resource_prefix}-hybrid-rag"
    Purpose    = "RAG test lambda - hybrid vector BM25 search"
    SearchType = "HYBRID"
  }
}

resource "aws_cloudwatch_log_group" "hybrid_rag_logs" {
  name              = "/aws/lambda/${local.resource_prefix}-hybrid-rag"
  retention_in_days = 14

  tags = {
    Name    = "${local.resource_prefix}-hybrid-rag-logs"
    Purpose = "Logs for hybrid RAG test lambda"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "hybrid_rag_lambda_name" {
  description = "Name of the hybrid RAG test lambda"
  value       = aws_lambda_function.hybrid_rag.function_name
}

output "hybrid_rag_lambda_arn" {
  description = "ARN of the hybrid RAG test lambda"
  value       = aws_lambda_function.hybrid_rag.arn
}
