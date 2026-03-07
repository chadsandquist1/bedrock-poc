# -----------------------------------------------------------------------------
# Citation Lambdas — Option 1 (RetrieveAndGenerate + span post-processing)
#                    Option 2 (Retrieve + Converse Citations API)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Zip archives
# -----------------------------------------------------------------------------
data "archive_file" "citations_v1_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/lambda_rag_citations_v1_handler.py"
  output_path = "${path.module}/../lambdas/lambda_rag_citations_v1_handler.zip"
}

data "archive_file" "citations_v2_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/lambda_rag_citations_v2_handler.py"
  output_path = "${path.module}/../lambdas/lambda_rag_citations_v2_handler.zip"
}

# -----------------------------------------------------------------------------
# IAM role — Option 1
# -----------------------------------------------------------------------------
resource "aws_iam_role" "citations_v1_lambda" {
  name = "${local.resource_prefix}-citations-v1-lambda-role"

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
    Name    = "${local.resource_prefix}-citations-v1-lambda-role"
    Purpose = "Execution role for RAG citations v1 lambda"
  }
}

resource "aws_iam_role_policy" "citations_v1_bedrock" {
  name = "${local.resource_prefix}-citations-v1-bedrock"
  role = aws_iam_role.citations_v1_lambda.id

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
        Resource = [
          local.claude_model_arn,
          local.claude_foundation_model_arn,
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "citations_v1_logging" {
  name = "${local.resource_prefix}-citations-v1-logging"
  role = aws_iam_role.citations_v1_lambda.id

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
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.resource_prefix}-rag-citations-v1:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# IAM role — Option 2
# -----------------------------------------------------------------------------
resource "aws_iam_role" "citations_v2_lambda" {
  name = "${local.resource_prefix}-citations-v2-lambda-role"

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
    Name    = "${local.resource_prefix}-citations-v2-lambda-role"
    Purpose = "Execution role for RAG citations v2 lambda"
  }
}

resource "aws_iam_role_policy" "citations_v2_bedrock" {
  name = "${local.resource_prefix}-citations-v2-bedrock"
  role = aws_iam_role.citations_v2_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock-agent:Retrieve"]
        Resource = local.rag_kb_arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:GetInferenceProfile",
        ]
        Resource = [
          local.claude_model_arn,
          local.claude_foundation_model_arn,
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "citations_v2_logging" {
  name = "${local.resource_prefix}-citations-v2-logging"
  role = aws_iam_role.citations_v2_lambda.id

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
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.resource_prefix}-rag-citations-v2:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda — Option 1 (RetrieveAndGenerate + span post-processing)
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "citations_v1" {
  filename         = data.archive_file.citations_v1_zip.output_path
  function_name    = "${local.resource_prefix}-rag-citations-v1"
  role             = aws_iam_role.citations_v1_lambda.arn
  handler          = "lambda_rag_citations_v1_handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.citations_v1_zip.output_base64sha256
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
    Name       = "${local.resource_prefix}-rag-citations-v1"
    Purpose    = "RAG citations lambda - RetrieveAndGenerate with span post-processing"
    SearchType = "SEMANTIC"
  }
}

resource "aws_cloudwatch_log_group" "citations_v1_logs" {
  name              = "/aws/lambda/${local.resource_prefix}-rag-citations-v1"
  retention_in_days = 14

  tags = {
    Name    = "${local.resource_prefix}-rag-citations-v1-logs"
    Purpose = "Logs for RAG citations v1 lambda"
  }
}

# -----------------------------------------------------------------------------
# Lambda — Option 2 (Retrieve + Converse Citations API)
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "citations_v2" {
  filename         = data.archive_file.citations_v2_zip.output_path
  function_name    = "${local.resource_prefix}-rag-citations-v2"
  role             = aws_iam_role.citations_v2_lambda.arn
  handler          = "lambda_rag_citations_v2_handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.citations_v2_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = local.rag_kb_id
      MODEL_ID          = local.claude_model_id
      NUMBER_OF_RESULTS = "5"
    }
  }

  tags = {
    Name    = "${local.resource_prefix}-rag-citations-v2"
    Purpose = "RAG citations lambda - Retrieve + Converse Citations API"
  }
}

resource "aws_cloudwatch_log_group" "citations_v2_logs" {
  name              = "/aws/lambda/${local.resource_prefix}-rag-citations-v2"
  retention_in_days = 14

  tags = {
    Name    = "${local.resource_prefix}-rag-citations-v2-logs"
    Purpose = "Logs for RAG citations v2 lambda"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "citations_v1_lambda_name" {
  description = "Name of the RAG citations v1 lambda (RetrieveAndGenerate + span)"
  value       = aws_lambda_function.citations_v1.function_name
}

output "citations_v2_lambda_name" {
  description = "Name of the RAG citations v2 lambda (Retrieve + Converse Citations API)"
  value       = aws_lambda_function.citations_v2.function_name
}
