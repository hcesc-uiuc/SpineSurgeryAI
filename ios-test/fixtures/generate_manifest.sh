#!/usr/bin/env bash
#
# generate_manifest.sh — Issue #69
#
# Regenerate manifest.json from the S3 fixtures prefix. Emits one entry per
# object with a presigned GET URL (so the bucket/prefix can stay private) and
# the kind inferred from the filename prefix — the same mapping the app uses in
# Uploader.uploadFolder.
#
# Rabbi's workflow: drop files into s3://$BUCKET/$PREFIX, then run this and
# upload the result back next to them:
#
#   BUCKET=my-bucket PREFIX=test-fixtures/ REGION=us-east-2 \
#     ./generate_manifest.sh > manifest.json
#   aws s3 cp manifest.json "s3://my-bucket/test-fixtures/manifest.json"
#
# Then point the harness's "Manifest URL" field at that manifest.json
# (public-read, or itself a presigned URL).
#
# Requires: awscli v2, credentials with s3:ListBucket + s3:GetObject on the prefix.

set -euo pipefail

BUCKET="${BUCKET:?set BUCKET=your-bucket}"
PREFIX="${PREFIX:-test-fixtures/}"
REGION="${REGION:-us-east-2}"
EXPIRES="${EXPIRES:-604800}"   # presigned URL lifetime, seconds (max 7 days)

kind_for() {
  case "$1" in
    accelerometer_*)      echo "accel" ;;
    locations_*)          echo "loc"   ;;
    healthkit_*)          echo "hk"    ;;
    sqlite_*|sensorkit_*) echo "other" ;;
    *)                    echo "other" ;;
  esac
}

printf '[\n'
sep=""
while read -r key; do
  [ -z "$key" ] && continue
  base="$(basename "$key")"
  case "$base" in ""|manifest.json) continue ;; esac   # skip folder key + the manifest itself
  kind="$(kind_for "$base")"
  url="$(aws s3 presign "s3://${BUCKET}/${key}" --expires-in "$EXPIRES" --region "$REGION")"
  printf '%s  {"filename": "%s", "kind": "%s", "url": "%s"}' "$sep" "$base" "$kind" "$url"
  sep=$',\n'
done < <(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$PREFIX" \
           --query 'Contents[].Key' --output text | tr '\t' '\n')
printf '\n]\n'
