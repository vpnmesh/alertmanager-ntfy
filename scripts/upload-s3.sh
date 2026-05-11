#!/usr/bin/env bash
# Upload alertmanager-ntfy release files to S3-compatible providers.
#
# Required env:
#   S3_TARGETS    JSON array of provider configs
#   VERSION_TAG   release tag, for example v0.1.0
#   VERSION_NAME  bare version, for example 0.1.0
#
# Optional env:
#   ARTIFACT_DIR   directory with files to upload, default dist
#   PATH_PREFIX    bucket prefix, default third_party
#   PLATFORM_ARCH  arch value for version.json, default amd64

set -euo pipefail

log() { echo "[s3] $*"; }
err() { echo "[s3][error] $*" >&2; }

ARTIFACT_DIR="${ARTIFACT_DIR:-dist}"
PATH_PREFIX="${PATH_PREFIX:-third_party}"
PLATFORM_ARCH="${PLATFORM_ARCH:-amd64}"
APP_NAME="alertmanager-ntfy"

if [[ -z "${S3_TARGETS:-}" ]]; then
  err "S3_TARGETS is not set"
  exit 1
fi

if [[ -z "${VERSION_TAG:-}" ]]; then
  err "VERSION_TAG is not set"
  exit 1
fi

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  err "ARTIFACT_DIR does not exist: $ARTIFACT_DIR"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI is required"
  exit 1
fi

mapfile -t ARTIFACTS < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f | sort)
if [[ "${#ARTIFACTS[@]}" -eq 0 ]]; then
  err "No artifacts found in $ARTIFACT_DIR"
  exit 1
fi

content_type_for_file() {
  case "$1" in
    *.json) echo "application/json" ;;
    *.txt) echo "text/plain" ;;
    *) echo "application/octet-stream" ;;
  esac
}

PROVIDER_COUNT=$(jq '. | length' <<<"$S3_TARGETS")
if [[ "$PROVIDER_COUNT" -eq 0 ]]; then
  err "S3_TARGETS is empty"
  exit 1
fi

VERSION_JSON=$(jq -n \
  --arg app "$APP_NAME" \
  --arg version_name "${VERSION_NAME:-}" \
  --arg version_tag "$VERSION_TAG" \
  --arg platform "linux" \
  --arg arch "$PLATFORM_ARCH" \
  --arg build_date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson files "$(printf '%s\n' "${ARTIFACTS[@]}" | xargs -n1 basename | jq -R . | jq -s .)" \
  '{app: $app, version_name: $version_name, version_tag: $version_tag, platform: $platform, arch: $arch, build_date: $build_date, files: $files}')

for i in $(seq 0 $((PROVIDER_COUNT - 1))); do
  PROVIDER_NAME=$(jq -r ".[$i].name" <<<"$S3_TARGETS")
  ENDPOINT=$(jq -r ".[$i].endpoint" <<<"$S3_TARGETS")
  BUCKET=$(jq -r ".[$i].bucket" <<<"$S3_TARGETS")
  REGION=$(jq -r ".[$i].region // \"us-east-1\"" <<<"$S3_TARGETS")
  ACCESS_KEY=$(jq -r ".[$i].access_key" <<<"$S3_TARGETS")
  SECRET_KEY=$(jq -r ".[$i].secret_key" <<<"$S3_TARGETS")
  ACL=$(jq -r ".[$i].acl // \"public-read\"" <<<"$S3_TARGETS")
  STORAGE_CLASS=$(jq -r ".[$i].storage_class // empty" <<<"$S3_TARGETS")

  S3_VERSION_PATH="s3://${BUCKET}/${PATH_PREFIX}/${VERSION_TAG}"
  S3_LATEST_PATH="s3://${BUCKET}/${PATH_PREFIX}/latest"

  if [[ -z "$ENDPOINT" || -z "$BUCKET" || -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
    err "Provider ${PROVIDER_NAME} has missing required fields"
    exit 1
  fi

  export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
  export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
  export AWS_DEFAULT_REGION="$REGION"

  EXTRA_ARGS=()
  if [[ -n "$ACL" && "$ACL" != "null" ]]; then
    EXTRA_ARGS+=(--acl "$ACL")
  fi
  if [[ -n "$STORAGE_CLASS" && "$STORAGE_CLASS" != "null" ]]; then
    EXTRA_ARGS+=(--storage-class "$STORAGE_CLASS")
  fi

  log "Provider: $PROVIDER_NAME"
  log "Uploading to ${S3_VERSION_PATH}/ and ${S3_LATEST_PATH}/"

  for artifact in "${ARTIFACTS[@]}"; do
    filename=$(basename "$artifact")
    content_type=$(content_type_for_file "$filename")

    aws s3 cp "$artifact" "${S3_VERSION_PATH}/${filename}" \
      --endpoint-url "$ENDPOINT" \
      --content-type "$content_type" \
      "${EXTRA_ARGS[@]}" \
      --no-progress

    aws s3 cp "$artifact" "${S3_LATEST_PATH}/${filename}" \
      --endpoint-url "$ENDPOINT" \
      --content-type "$content_type" \
      "${EXTRA_ARGS[@]}" \
      --no-progress
  done

  printf '%s\n' "$VERSION_JSON" | aws s3 cp - "${S3_VERSION_PATH}/version.json" \
    --endpoint-url "$ENDPOINT" \
    --content-type "application/json" \
    "${EXTRA_ARGS[@]}" \
    --no-progress

  printf '%s\n' "$VERSION_JSON" | aws s3 cp - "${S3_LATEST_PATH}/version.json" \
    --endpoint-url "$ENDPOINT" \
    --content-type "application/json" \
    "${EXTRA_ARGS[@]}" \
    --no-progress

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
done

log "Upload complete"