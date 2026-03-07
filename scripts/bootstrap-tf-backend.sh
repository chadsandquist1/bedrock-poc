#!/usr/bin/env bash
# One-time setup: S3 state bucket + DynamoDB lock table.
# Idempotent — safe to re-run.
# NOTE: Already bootstrapped for this repo — do not re-run unless recreating from scratch.
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="bedrock-rag-tfstate-${ACCOUNT_ID}"
TABLE="bedrock-rag-tfstate-lock"

echo "Account: $ACCOUNT_ID | Bucket: $BUCKET | Table: $TABLE"

# S3 bucket (us-east-1 requires no LocationConstraint)
aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>&1 \
  | grep -v BucketAlreadyOwnedByYou || true

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# DynamoDB lock table
TABLE_STATUS=$(aws dynamodb describe-table --table-name "$TABLE" --region "$AWS_REGION" \
  --query "Table.TableStatus" --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$TABLE_STATUS" = "NOT_FOUND" ]; then
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$AWS_REGION"
  echo "DynamoDB table created."
else
  echo "DynamoDB table already exists ($TABLE_STATUS), skipping."
fi

echo ""
echo "Bootstrap complete! Next:"
echo "  1. Add backend block to terraform/providers.tf"
echo "  2. cd terraform && terraform init -migrate-state"
echo "  3. Confirm 'yes' to migrate"
echo "  4. rm terraform/terraform.tfstate terraform/terraform.tfstate.backup"
echo "  5. Add GitHub Secrets, then commit and push"
