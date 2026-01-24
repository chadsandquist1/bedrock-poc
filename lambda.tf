data "archive_file" "ingestion_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/scripts/lambda_ingestion_handler.py"
  output_path = "${path.module}/scripts/lambda_ingestion_handler.zip"
}

resource "aws_iam_role" "ingestion_lambda_execution" {
  name = "${local.resource_prefix}-ingestion-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "${local.resource_prefix}-ingestion-lambda-role"
    Purpose = "Lambda execution role for KB ingestion handler"
  }
}

resource "aws_iam_role_policy" "ingestion_lambda_logging" {
  name = "${local.resource_prefix}-ingestion-lambda-logging"
  role = aws_iam_role.ingestion_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.resource_prefix}-ingestion-handler:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda Function
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "ingestion_handler" {
  filename      = data.archive_file.ingestion_lambda_zip.output_path
  function_name = "${local.resource_prefix}-ingestion-handler"
  role          = aws_iam_role.ingestion_lambda_execution.arn
  handler       = "lambda_ingestion_handler.lambda_handler"
  runtime       = "python3.11"

  source_code_hash = data.archive_file.ingestion_lambda_zip.output_base64sha256

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = local.knowledge_base_id
    }
  }

  tags = {
    Name    = "${local.resource_prefix}-ingestion-handler"
    Purpose = "Handle Bedrock KB ingestion state change events"
  }
}

resource "aws_cloudwatch_log_group" "ingestion_lambda_logs" {
  name              = "/aws/lambda/${local.resource_prefix}-ingestion-handler"
  retention_in_days = 14

  tags = {
    Name    = "${local.resource_prefix}-ingestion-handler-logs"
    Purpose = "Logs for KB ingestion handler Lambda"
  }
}

output "ingestion_lambda_arn" {
  description = "ARN of the ingestion handler Lambda function"
  value       = aws_lambda_function.ingestion_handler.arn
}

output "ingestion_lambda_name" {
  description = "Name of the ingestion handler Lambda function"
  value       = aws_lambda_function.ingestion_handler.function_name
}
