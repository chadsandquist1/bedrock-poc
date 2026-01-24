# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  region             = var.aws_region
  vector_bucket_name = "${var.vector_bucket_name}-${local.account_id}"
  resource_prefix    = "${var.project_name}-${var.environment}"
  knowledge_base_id  = "ZI2DHYWRGS" # Hardcoded KB ID for CloudWatch Logs filtering
}

# -----------------------------------------------------------------------------
# S3 Bucket for source documents
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "documents" {
  bucket = "${local.resource_prefix}-documents-${local.account_id}"

  tags = {
    Name = "${local.resource_prefix}-documents"
  }
}

resource "aws_s3_bucket_versioning" "documents" {
  bucket = aws_s3_bucket.documents.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  bucket = aws_s3_bucket.documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  bucket = aws_s3_bucket.documents.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# IAM Role for Bedrock Knowledge Base
# -----------------------------------------------------------------------------
resource "aws_iam_role" "bedrock_kb" {
  name = "${local.resource_prefix}-bedrock-kb-role"

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

# Policy for S3 document access
resource "aws_iam_role_policy" "bedrock_kb_s3" {
  name = "${local.resource_prefix}-bedrock-kb-s3-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.documents.arn,
          "${aws_s3_bucket.documents.arn}/*"
        ]
      }
    ]
  })
}

# Policy for S3 Vectors access
resource "aws_iam_role_policy" "bedrock_kb_vectors" {
  name = "${local.resource_prefix}-bedrock-kb-vectors-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3vectors:*"
        ]
        Resource = [
          "arn:aws:s3vectors:${local.region}:${local.account_id}:bucket/${local.vector_bucket_name}",
          "arn:aws:s3vectors:${local.region}:${local.account_id}:bucket/${local.vector_bucket_name}/*"
        ]
      }
    ]
  })
}

# Policy for Bedrock model access (Titan Embeddings - cheapest option)
resource "aws_iam_role_policy" "bedrock_kb_model" {
  name = "${local.resource_prefix}-bedrock-kb-model-policy"
  role = aws_iam_role.bedrock_kb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          "arn:aws:bedrock:${local.region}::foundation-model/amazon.titan-embed-text-v2:0"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# S3 Vectors Store (via null_resource)
# -----------------------------------------------------------------------------
resource "null_resource" "s3_vector_bucket" {
  triggers = {
    vector_bucket_name = local.vector_bucket_name
    region             = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws s3vectors create-vector-bucket \
        --vector-bucket-name "${local.vector_bucket_name}" \
        --region ${local.region} || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws s3vectors delete-vector-bucket \
        --vector-bucket-name "${self.triggers.vector_bucket_name}" \
        --region ${self.triggers.region} || true
    EOT
  }
}

# Wait for vector bucket to be ready
resource "time_sleep" "wait_for_vector_bucket" {
  depends_on = [null_resource.s3_vector_bucket]

  create_duration = "30s"
}

resource "null_resource" "s3_vector_index" {
  depends_on = [time_sleep.wait_for_vector_bucket]

  triggers = {
    vector_bucket_name = local.vector_bucket_name
    index_name         = var.vector_index_name
    dimension          = var.embedding_dimension
    distance_metric    = var.distance_metric
    region             = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws s3vectors create-index \
        --vector-bucket-name "${local.vector_bucket_name}" \
        --index-name "${var.vector_index_name}" \
        --data-type float32 \
        --dimension ${var.embedding_dimension} \
        --distance-metric ${var.distance_metric} \
        --region ${local.region} || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws s3vectors delete-index \
        --vector-bucket-name "${self.triggers.vector_bucket_name}" \
        --index-name "${self.triggers.index_name}" \
        --region ${self.triggers.region} || true
    EOT
  }
}

# Wait for vector index to be ready
resource "time_sleep" "wait_for_vector_index" {
  depends_on = [null_resource.s3_vector_index]

  create_duration = "30s"
}

# -----------------------------------------------------------------------------
# Bedrock Knowledge Base with S3 Vectors (via null_resource)
# S3 Vectors storage type may not be fully supported in Terraform AWS provider yet
# -----------------------------------------------------------------------------
resource "null_resource" "bedrock_knowledge_base" {
  depends_on = [
    time_sleep.wait_for_vector_index,
    aws_iam_role.bedrock_kb,
    aws_iam_role_policy.bedrock_kb_s3,
    aws_iam_role_policy.bedrock_kb_vectors,
    aws_iam_role_policy.bedrock_kb_model
  ]

  triggers = {
    kb_name            = "${local.resource_prefix}-knowledge-base"
    role_arn           = aws_iam_role.bedrock_kb.arn
    vector_bucket_name = local.vector_bucket_name
    index_name         = var.vector_index_name
    region             = local.region
    account_id         = local.account_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Create the Knowledge Base with S3 Vectors storage
      KB_RESPONSE=$(aws bedrock-agent create-knowledge-base \
        --name "${local.resource_prefix}-knowledge-base" \
        --role-arn "${aws_iam_role.bedrock_kb.arn}" \
        --knowledge-base-configuration '{
          "type": "VECTOR",
          "vectorKnowledgeBaseConfiguration": {
            "embeddingModelArn": "arn:aws:bedrock:${local.region}::foundation-model/amazon.titan-embed-text-v2:0"
          }
        }' \
        --storage-configuration '{
          "type": "S3_VECTORS",
          "s3VectorsConfiguration": {
            "vectorBucketArn": "arn:aws:s3vectors:${local.region}:${local.account_id}:bucket/${local.vector_bucket_name}",
            "indexName": "${var.vector_index_name}"
          }
        }' \
        --region ${local.region} 2>&1) || true

      echo "$KB_RESPONSE"

      # Extract Knowledge Base ID
      KB_ID=$(echo "$KB_RESPONSE" | jq -r '.knowledgeBase.knowledgeBaseId // empty')

      if [ -n "$KB_ID" ]; then
        echo "$KB_ID" > /tmp/kb_id_${local.resource_prefix}.txt
        echo "Knowledge Base created with ID: $KB_ID"
      else
        echo "Failed to create Knowledge Base or already exists"
        # Try to get existing KB ID
        EXISTING_KB=$(aws bedrock-agent list-knowledge-bases --region ${local.region} | jq -r '.knowledgeBaseSummaries[] | select(.name=="${local.resource_prefix}-knowledge-base") | .knowledgeBaseId')
        if [ -n "$EXISTING_KB" ]; then
          echo "$EXISTING_KB" > /tmp/kb_id_${local.resource_prefix}.txt
          echo "Using existing Knowledge Base: $EXISTING_KB"
        fi
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      KB_ID=$(cat /tmp/kb_id_${self.triggers.kb_name}.txt 2>/dev/null || echo "")
      if [ -n "$KB_ID" ]; then
        aws bedrock-agent delete-knowledge-base \
          --knowledge-base-id "$KB_ID" \
          --region ${self.triggers.region} || true
      fi
    EOT
  }
}

# Wait for Knowledge Base to be ready
resource "time_sleep" "wait_for_knowledge_base" {
  depends_on = [null_resource.bedrock_knowledge_base]

  create_duration = "30s"
}

# -----------------------------------------------------------------------------
# Bedrock Knowledge Base Data Source with Semantic Chunking (via null_resource)
# -----------------------------------------------------------------------------
resource "null_resource" "bedrock_data_source" {
  depends_on = [time_sleep.wait_for_knowledge_base]

  triggers = {
    kb_name             = "${local.resource_prefix}-knowledge-base"
    data_source_name    = "${local.resource_prefix}-documents-source"
    documents_bucket    = aws_s3_bucket.documents.arn
    max_tokens          = var.max_tokens
    buffer_size         = var.buffer_size
    breakpoint_threshold = var.breakpoint_percentile_threshold
    region              = local.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Get Knowledge Base ID
      KB_ID=$(cat /tmp/kb_id_${local.resource_prefix}-knowledge-base.txt 2>/dev/null || echo "")

      if [ -z "$KB_ID" ]; then
        KB_ID=$(aws bedrock-agent list-knowledge-bases --region ${local.region} | jq -r '.knowledgeBaseSummaries[] | select(.name=="${local.resource_prefix}-knowledge-base") | .knowledgeBaseId')
      fi

      if [ -n "$KB_ID" ]; then
        # Create Data Source with semantic chunking
        DS_RESPONSE=$(aws bedrock-agent create-data-source \
          --knowledge-base-id "$KB_ID" \
          --name "${local.resource_prefix}-documents-source" \
          --data-source-configuration '{
            "type": "S3",
            "s3Configuration": {
              "bucketArn": "${aws_s3_bucket.documents.arn}"
            }
          }' \
          --vector-ingestion-configuration '{
            "chunkingConfiguration": {
              "chunkingStrategy": "SEMANTIC",
              "semanticChunkingConfiguration": {
                "maxTokens": ${var.max_tokens},
                "bufferSize": ${var.buffer_size},
                "breakpointPercentileThreshold": ${var.breakpoint_percentile_threshold}
              }
            }
          }' \
          --data-deletion-policy DELETE \
          --region ${local.region} 2>&1) || true

        echo "$DS_RESPONSE"

        DS_ID=$(echo "$DS_RESPONSE" | jq -r '.dataSource.dataSourceId // empty')
        if [ -n "$DS_ID" ]; then
          echo "$DS_ID" > /tmp/ds_id_${local.resource_prefix}.txt
          echo "Data Source created with ID: $DS_ID"
        fi
      else
        echo "Knowledge Base ID not found"
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      KB_ID=$(cat /tmp/kb_id_${self.triggers.kb_name}.txt 2>/dev/null || echo "")
      DS_ID=$(cat /tmp/ds_id_${self.triggers.kb_name}.txt 2>/dev/null || echo "")

      if [ -n "$KB_ID" ] && [ -n "$DS_ID" ]; then
        aws bedrock-agent delete-data-source \
          --knowledge-base-id "$KB_ID" \
          --data-source-id "$DS_ID" \
          --region ${self.triggers.region} || true
      fi
    EOT
  }
}
