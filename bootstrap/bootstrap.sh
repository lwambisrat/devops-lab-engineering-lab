#!/usr/bin/env bash
set -euo pipefail

BUCKET="${STATE_BUCKET:-regional-health-tfstate}"
LOCK_TABLE="${LOCK_TABLE:-regional-health-tflock}"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="$REGION"

echo ">> Ensuring Terraform state bucket exists: ${BUCKET}"
if ! aws --endpoint-url="$AWS_ENDPOINT_URL" s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws --endpoint-url="$AWS_ENDPOINT_URL" s3api create-bucket --bucket "$BUCKET" >/dev/null
fi

echo ">> Ensuring Terraform lock table exists: ${LOCK_TABLE}"
if ! aws --endpoint-url="$AWS_ENDPOINT_URL" dynamodb describe-table --table-name "$LOCK_TABLE" >/dev/null 2>&1; then
  aws --endpoint-url="$AWS_ENDPOINT_URL" dynamodb create-table \
    --table-name "$LOCK_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
fi

echo ">> Bootstrap complete."
