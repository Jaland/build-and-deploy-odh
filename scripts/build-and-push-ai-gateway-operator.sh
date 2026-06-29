#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker; set IMAGE_BUILDER=docker for make.
#
# Builds and pushes the AI Gateway module operator image from
# https://github.com/opendatahub-io/ai-gateway-operator
#
# Required env:
#   AI_GATEWAY_IMAGE_REPO  Full image path without tag (default: quay.io/maas/ai-gateway-operator)
#   QUAY_USERNAME          Registry user (optional if already logged in via podman/docker login)
#   QUAY_PASSWORD          Registry password or robot token (optional with existing login)
#
# Optional env:
#   UNIFIED_IMAGE_TAG      Same tag semantics as the ODH build (overrides IMG_TAG)
#   IMG_TAG                Image tag when UNIFIED_IMAGE_TAG is unset (default: latest)
#   AI_GATEWAY_REPO_URL    Clone URL (default: upstream GitHub)
#   AI_GATEWAY_GIT_REF     Branch, tag, or commit (default: main)
#   AI_GATEWAY_CLONE_DIR   Clone destination (default: ./ai-gateway-operator; CLONE_DIR legacy alias)
#   SKIP_GET_MANIFESTS     If 1, skip make get-manifests
#   IMAGE_BUILDER          podman or docker (default: podman)
#   MAAS_REPO_URL / MAAS_GIT_REF  Override maascontroller pin in hack/scripts/get-manifests.sh
#                                 (required for Somya ai-gateway PR #29; use Ryan fork for #1025)
#   USE_LOCAL                     If true, copy from ../models-as-a-service adjacent checkout
#   MAAS_CLONE_DIR                Local clone for USE_LOCAL (default: <repo>/models-as-a-service)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/component-ref.sh
source "${SCRIPT_DIR}/lib/component-ref.sh"

ensure_go_toolchain
IMG_TAG="${IMG_TAG:-latest}"
resolve_unified_image_tag

AI_GATEWAY_REPO_URL="${AI_GATEWAY_REPO_URL:-https://github.com/opendatahub-io/ai-gateway-operator.git}"
AI_GATEWAY_GIT_REF="${AI_GATEWAY_GIT_REF:-main}"
AI_GATEWAY_CLONE_DIR="${AI_GATEWAY_CLONE_DIR:-${CLONE_DIR:-./ai-gateway-operator}}"
SKIP_GET_MANIFESTS="${SKIP_GET_MANIFESTS:-0}"
IMAGE_BUILDER="${IMAGE_BUILDER:-podman}"

AI_GATEWAY_IMAGE_REPO="${AI_GATEWAY_IMAGE_REPO:-${QUAY_AI_GATEWAY_REPO:-quay.io/maas/ai-gateway-operator}}"

ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_OUTPUT_ENV="${BUILD_OUTPUT_ENV:-${ROOT}/ai-gateway-build-output.env}"
cd "${ROOT}"

clone_git_repo "${AI_GATEWAY_REPO_URL}" "${AI_GATEWAY_GIT_REF}" "${AI_GATEWAY_CLONE_DIR}"
cd "${AI_GATEWAY_CLONE_DIR}"

login_registry_hosts "${IMAGE_BUILDER}" "${QUAY_USERNAME:-}" "${QUAY_PASSWORD:-}" "${AI_GATEWAY_IMAGE_REPO}"

export CONTAINER_TOOL="${IMAGE_BUILDER}"
AI_GATEWAY_IMAGE="${AI_GATEWAY_IMAGE_REPO}:${IMG_TAG}"
export IMG="${AI_GATEWAY_IMAGE}"

if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
  echo "Fetching sub-component manifests (make get-manifests)..."
  prepare_ai_gateway_maas_manifests "$(pwd)" "${ROOT}"
  make get-manifests
else
  echo "Skipping get-manifests"
fi

echo "Building and pushing AI Gateway operator image (${AI_GATEWAY_IMAGE})..."
make container-build container-push

{
  echo "AI_GATEWAY_IMAGE=${AI_GATEWAY_IMAGE}"
  echo "AI_GATEWAY_IMAGE_REPO=${AI_GATEWAY_IMAGE_REPO}"
  echo "AI_GATEWAY_REPO_URL=${AI_GATEWAY_REPO_URL}"
  echo "AI_GATEWAY_GIT_REF=${AI_GATEWAY_GIT_REF}"
  echo "MAAS_REPO_URL=${MAAS_REPO_URL:-${MAAS_MANIFEST_REPO_URL:-}}"
  echo "MAAS_GIT_REF=${MAAS_GIT_REF:-${MAAS_MANIFEST_REF:-}}"
  echo "AI_GATEWAY_MAAS_MANIFEST_REF=${AI_GATEWAY_MAAS_MANIFEST_REF:-}"
  echo "IMG_TAG=${IMG_TAG}"
  echo "UNIFIED_IMAGE_TAG=${UNIFIED_IMAGE_TAG:-}"
} | tee "${BUILD_OUTPUT_ENV}"

echo ""
echo "========== AI Gateway build complete =========="
echo "Image: ${AI_GATEWAY_IMAGE}"
echo "==============================================="
