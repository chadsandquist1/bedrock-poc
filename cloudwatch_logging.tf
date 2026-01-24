# -----------------------------------------------------------------------------
# CloudWatch Logs Subscription Filter for Bedrock Knowledge Base Ingestion
#
# Triggers a Lambda function when KB ingestion job status changes are logged.
# The log group is auto-created by AWS when enabling Log Delivery on the KB.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Local variable for the vendedlogs log group name
# -----------------------------------------------------------------------------
locals {
  kb_vendedlogs_group = "/aws/vendedlogs/bedrock/knowledge-base/APPLICATION_LOGS/${local.knowledge_base_id}"
}

# -----------------------------------------------------------------------------
# CloudWatch Logs Subscription Filter
# Triggers Lambda when ingestion job events are logged
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_subscription_filter" "kb_ingestion_filter" {
  name            = "${local.resource_prefix}-kb-ingestion-filter"
  log_group_name  = local.kb_vendedlogs_group
  filter_pattern  = ""
  destination_arn = aws_lambda_function.ingestion_handler.arn

  depends_on = [aws_lambda_permission.cloudwatch_logs_invoke]
}

# -----------------------------------------------------------------------------
# Lambda Permission for CloudWatch Logs
# Allows CloudWatch Logs to invoke the Lambda function
# -----------------------------------------------------------------------------
resource "aws_lambda_permission" "cloudwatch_logs_invoke" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion_handler.function_name
  principal     = "logs.${local.region}.amazonaws.com"
  source_arn    = "arn:aws:logs:${local.region}:${local.account_id}:log-group:${local.kb_vendedlogs_group}:*"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "kb_application_log_group" {
  description = "CloudWatch Log Group for KB application logs (vendedlogs)"
  value       = local.kb_vendedlogs_group
}
