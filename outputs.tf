output "documents_bucket_name" {
  description = "Name of the S3 bucket for source documents"
  value       = aws_s3_bucket.documents.id
}

output "documents_bucket_arn" {
  description = "ARN of the S3 bucket for source documents"
  value       = aws_s3_bucket.documents.arn
}

output "vector_bucket_name" {
  description = "Name of the S3 vector bucket"
  value       = local.vector_bucket_name
}

output "vector_index_name" {
  description = "Name of the vector index"
  value       = var.vector_index_name
}

output "knowledge_base_name" {
  description = "Name of the Bedrock Knowledge Base"
  value       = "${local.resource_prefix}-knowledge-base"
}

output "data_source_name" {
  description = "Name of the Knowledge Base data source"
  value       = "${local.resource_prefix}-documents-source"
}

output "bedrock_role_arn" {
  description = "ARN of the IAM role used by Bedrock Knowledge Base"
  value       = aws_iam_role.bedrock_kb.arn
}

output "embedding_model" {
  description = "Embedding model used for the knowledge base"
  value       = "amazon.titan-embed-text-v2:0"
}

output "chunking_strategy" {
  description = "Chunking strategy used for document processing"
  value       = "SEMANTIC"
}

output "get_knowledge_base_id_command" {
  description = "Command to get the Knowledge Base ID"
  value       = "aws bedrock-agent list-knowledge-bases --region ${var.aws_region} | jq -r '.knowledgeBaseSummaries[] | select(.name==\"${local.resource_prefix}-knowledge-base\") | .knowledgeBaseId'"
}

output "get_data_source_id_command" {
  description = "Command to get the Data Source ID (requires KB_ID)"
  value       = "aws bedrock-agent list-data-sources --knowledge-base-id <KB_ID> --region ${var.aws_region} | jq -r '.dataSourceSummaries[0].dataSourceId'"
}
