variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "bedrock-rag"
}

variable "vector_bucket_name" {
  description = "Name for the S3 vector bucket"
  type        = string
  default     = "rag-vector-store"
}

variable "vector_index_name" {
  description = "Name for the vector index"
  type        = string
  default     = "kb-index"
}

variable "embedding_dimension" {
  description = "Dimension of the embedding vectors (1024 for Titan Embeddings V2)"
  type        = number
  default     = 1024
}

variable "distance_metric" {
  description = "Distance metric for vector similarity"
  type        = string
  default     = "cosine"
}

# Semantic chunking configuration
variable "max_tokens" {
  description = "Maximum tokens per chunk for semantic chunking"
  type        = number
  default     = 300
}

variable "buffer_size" {
  description = "Buffer size for semantic chunking (number of sentences)"
  type        = number
  default     = 1
}

variable "breakpoint_percentile_threshold" {
  description = "Percentile threshold for semantic breakpoints"
  type        = number
  default     = 95
}
