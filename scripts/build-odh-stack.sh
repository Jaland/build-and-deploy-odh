#!/usr/bin/env bash
# Build the ODH stack: AI Gateway module operator, then ODH operator + bundle + catalog.
# Flow: ODH operator → AI Gateway → MaaS (manifests wired via get_all_manifests.sh overrides).
#
# Optional: IMAGE_TAG_BASE or QUAY_REPO (default: quay.io/maas/opendatahub-operator).
# QUAY_USERNAME / QUAY_PASSWORD optional locally when podman/docker is already logged in to the registry hosts.
# Optional: AI_GATEWAY_IMAGE_REPO or QUAY_AI_GATEWAY_REPO (default: quay.io/maas/ai-gateway-operator).
#
# Component sources (repo + ref only; upstream defaults when unset):
#   OPERATOR_REPO_URL / OPERATOR_GIT_REF
#   AI_GATEWAY_REPO_URL / AI_GATEWAY_GIT_REF
#   MAAS_REPO_URL / MAAS_GIT_REF  (optional MAAS_SOURCE_PATH, default deployment)
#
# Tagging: UNIFIED_IMAGE_TAG applies to operator, bundle, catalog, and AI Gateway images.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AI_GATEWAY_IMAGE_REPO="${AI_GATEWAY_IMAGE_REPO:-${QUAY_AI_GATEWAY_REPO:-quay.io/maas/ai-gateway-operator}}"

export AI_GATEWAY_IMAGE_REPO
export BUILD_OUTPUT_ENV="${ROOT}/ai-gateway-build-output.env"
"${SCRIPT_DIR}/build-and-push-ai-gateway-operator.sh"

set -a
# shellcheck source=/dev/null
source "${BUILD_OUTPUT_ENV}"
set +a

export AI_GATEWAY_IMAGE
export BUILD_OUTPUT_ENV="${ROOT}/build-output.env"
"${SCRIPT_DIR}/build-and-push-odh-operator.sh"

echo ""
echo "Stack build complete. See ${ROOT}/build-output.env and ${ROOT}/ai-gateway-build-output.env"
