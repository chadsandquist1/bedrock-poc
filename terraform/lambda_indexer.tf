# -----------------------------------------------------------------------------
# Document Indexer Lambda
#
# On-demand Lambda that lists .txt files in the documents bucket, generates:
#   - document-index.txt: plain-text filename index for vector search
#   - <file>.metadata.json: per-file metadata for programmatic filtering
# Then starts a Bedrock ingestion job to re-ingest everything.
#
# Invoke manually after uploading new documents:
#   aws lambda invoke --function-name <name> --payload '{}' \
#     --cli-binary-format raw-in-base64-out /dev/stdout
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Zip archive
# -----------------------------------------------------------------------------
data "archive_file" "document_indexer_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/lambda_document_indexer_handler.py"
  output_path = "${path.module}/../lambdas/lambda_document_indexer_handler.zip"
}

# -----------------------------------------------------------------------------
# IAM role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "document_indexer_lambda" {
  name = "${local.resource_prefix}-document-indexer-lambda-role"

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
    Name    = "${local.resource_prefix}-document-indexer-lambda-role"
    Purpose = "Execution role for document indexer lambda"
  }
}

resource "aws_iam_role_policy" "document_indexer_s3" {
  name = "${local.resource_prefix}-document-indexer-s3"
  role = aws_iam_role.document_indexer_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.documents.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.documents.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "document_indexer_bedrock" {
  name = "${local.resource_prefix}-document-indexer-bedrock"
  role = aws_iam_role.document_indexer_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:StartIngestionJob"]
        Resource = local.rag_kb_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "document_indexer_logging" {
  name = "${local.resource_prefix}-document-indexer-logging"
  role = aws_iam_role.document_indexer_lambda.id

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
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${local.resource_prefix}-document-indexer:*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Lambda function
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "document_indexer" {
  filename         = data.archive_file.document_indexer_zip.output_path
  function_name    = "${local.resource_prefix}-document-indexer"
  role             = aws_iam_role.document_indexer_lambda.arn
  handler          = "lambda_document_indexer_handler.lambda_handler"
  runtime          = "python3.11"
  source_code_hash = data.archive_file.document_indexer_zip.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      DOCUMENTS_BUCKET  = aws_s3_bucket.documents.id
      KNOWLEDGE_BASE_ID = local.knowledge_base_id
      DATA_SOURCE_ID    = local.data_source_id
    }
  }

  tags = {
    Name    = "${local.resource_prefix}-document-indexer"
    Purpose = "Generate document-index.txt and metadata files then trigger ingestion"
  }
}

resource "aws_cloudwatch_log_group" "document_indexer_logs" {
  name              = "/aws/lambda/${local.resource_prefix}-document-indexer"
  retention_in_days = 14

  tags = {
    Name    = "${local.resource_prefix}-document-indexer-logs"
    Purpose = "Logs for document indexer lambda"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "document_indexer_lambda_name" {
  description = "Name of the document indexer lambda"
  value       = aws_lambda_function.document_indexer.function_name
}

output "invoke_document_indexer_command" {
  description = "AWS CLI command to invoke the document indexer"
  value       = "aws lambda invoke --function-name ${aws_lambda_function.document_indexer.function_name} --payload '{}' --cli-binary-format raw-in-base64-out /dev/stdout"
}
