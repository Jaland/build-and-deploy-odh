#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker; set IMAGE_BUILDER=docker for make.
#
# Builds and pushes the Open Data Hub operator image, OLM bundle, and FBC catalog
# from https://github.com/opendatahub-io/opendatahub-operator
#
# Required env:
#   IMAGE_TAG_BASE  Full image path without tag for operator + bundle, e.g. quay.io/myorg/opendatahub-operator
#   QUAY_USERNAME   Registry user (registry login; same creds for operator and catalog)
#   QUAY_PASSWORD   Registry password or robot token
#
# Optional env:
#   CATALOG_REPO    Separate catalog image path without tag (e.g. quay.io/myorg/odh-catalog-index).
#                   If unset, catalog is ${IMAGE_TAG_BASE}-catalog:v$VERSION (upstream default).
#   IMG_TAG           Operator image tag (default: latest)
#   VERSION           OLM bundle/catalog version string used in bundle tag v$VERSION (Makefile default if unset)
#   OPERATOR_GIT_REF  Branch, tag, or commit to build (default: main)
#   OPERATOR_REPO_URL Clone URL (default: upstream GitHub)
#   CLONE_DIR         Where to clone the operator repo (default: ./opendatahub-operator)
#   SKIP_GET_MANIFESTS  If 1, skip make get-manifests (not recommended for release-like builds)
#   DEPLOY_BUNDLE     If 1, run operator-sdk run bundle after push (needs oc/kubectl + kubeconfig)
#   OPERATOR_NAMESPACE Namespace for bundle install (default: opendatahub-operator-system)
#   OLM_DECOMPRESSION_IMAGE Image for operator-sdk bundle unpack (default from upstream README)
#   IMAGE_BUILDER     podman or docker (default: podman)
#   BUILD_OUTPUT_ENV  Path for KEY=value summary (default: <repo>/build-output.env)
#
set -euo pipefail

IMG_TAG="${IMG_TAG:-latest}"
OPERATOR_GIT_REF="${OPERATOR_GIT_REF:-main}"
OPERATOR_REPO_URL="${OPERATOR_REPO_URL:-https://github.com/opendatahub-io/opendatahub-operator.git}"
CLONE_DIR="${CLONE_DIR:-./opendatahub-operator}"
SKIP_GET_MANIFESTS="${SKIP_GET_MANIFESTS:-0}"
DEPLOY_BUNDLE="${DEPLOY_BUNDLE:-0}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-opendatahub-operator-system}"
IMAGE_BUILDER="${IMAGE_BUILDER:-podman}"
OLM_DECOMPRESSION_IMAGE="${OLM_DECOMPRESSION_IMAGE:-quay.io/project-codeflare/busybox:1.36}"

if [[ -z "${IMAGE_TAG_BASE:-}" ]]; then
  echo "ERROR: IMAGE_TAG_BASE is required (e.g. quay.io/myorg/opendatahub-operator)" >&2
  exit 1
fi
if [[ -z "${QUAY_USERNAME:-}" || -z "${QUAY_PASSWORD:-}" ]]; then
  echo "ERROR: QUAY_USERNAME and QUAY_PASSWORD are required" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_OUTPUT_ENV="${BUILD_OUTPUT_ENV:-${ROOT}/build-output.env}"
cd "$ROOT"

if [[ ! -d "$CLONE_DIR/.git" ]]; then
  rm -rf "$CLONE_DIR"
  git clone --depth 1 --branch "$OPERATOR_GIT_REF" "$OPERATOR_REPO_URL" "$CLONE_DIR" 2>/dev/null || {
    git clone "$OPERATOR_REPO_URL" "$CLONE_DIR"
    git -C "$CLONE_DIR" fetch --depth 1 origin "$OPERATOR_GIT_REF"
    git -C "$CLONE_DIR" checkout "$OPERATOR_GIT_REF"
  }
else
  echo "Using existing clone at $CLONE_DIR"
  git -C "$CLONE_DIR" fetch origin
  git -C "$CLONE_DIR" checkout "$OPERATOR_GIT_REF"
  git -C "$CLONE_DIR" pull --ff-only 2>/dev/null || true
fi

cd "$CLONE_DIR"

# Log in once per registry host (operator/bundle and optional catalog may use different repos or hosts).
login_registry_hosts() {
  local host
  while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    echo "Logging in to ${host}..."
    echo "${QUAY_PASSWORD}" | "${IMAGE_BUILDER}" login "${host}" -u "${QUAY_USERNAME}" --password-stdin
  done < <(for ref in "$@"; do [[ -z "${ref}" ]] && continue; echo "${ref%%/*}"; done | sort -u)
}
login_registry_hosts "${IMAGE_TAG_BASE}" "${CATALOG_REPO:-}"

export IMAGE_BUILDER

MAKE_ARGS=(IMAGE_TAG_BASE="${IMAGE_TAG_BASE}" IMG_TAG="${IMG_TAG}")
if [[ -n "${VERSION:-}" ]]; then
  MAKE_ARGS+=(VERSION="${VERSION}")
fi

if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
  echo "Fetching component manifests (make get-manifests)..."
  make "${MAKE_ARGS[@]}" get-manifests
else
  echo "Skipping get-manifests"
fi

echo "Building and pushing operator image..."
make "${MAKE_ARGS[@]}" image

echo "Building and pushing bundle image..."
make "${MAKE_ARGS[@]}" bundle-build bundle-push

VERSION_RESOLVED="$(make "${MAKE_ARGS[@]}" -s print-VERSION)"
if [[ -n "${CATALOG_REPO:-}" ]]; then
  CATALOG_IMG="${CATALOG_REPO}:v${VERSION_RESOLVED}"
else
  CATALOG_IMG="${IMAGE_TAG_BASE}-catalog:v${VERSION_RESOLVED}"
fi

echo "Building and pushing catalog image..."
make "${MAKE_ARGS[@]}" CATALOG_IMG="${CATALOG_IMG}" catalog-build catalog-push

OPERATOR_IMG="${IMAGE_TAG_BASE}:${IMG_TAG}"
BUNDLE_IMG="${IMAGE_TAG_BASE}-bundle:v${VERSION_RESOLVED}"

{
  echo "OPERATOR_IMAGE=${OPERATOR_IMG}"
  echo "BUNDLE_IMAGE=${BUNDLE_IMG}"
  echo "CATALOG_IMAGE=${CATALOG_IMG}"
  echo "IMAGE_TAG_BASE=${IMAGE_TAG_BASE}"
  echo "CATALOG_REPO=${CATALOG_REPO:-}"
  echo "IMG_TAG=${IMG_TAG}"
  echo "VERSION=${VERSION_RESOLVED}"
} | tee "$BUILD_OUTPUT_ENV"

echo ""
echo "========== Build complete =========="
echo "Operator image: ${OPERATOR_IMG}"
echo "Bundle image:   ${BUNDLE_IMG}"
echo "Catalog image:  ${CATALOG_IMG}"
echo "===================================="

if [[ "${DEPLOY_BUNDLE}" == "1" ]]; then
  echo "Deploying bundle to cluster (operator-sdk run bundle)..."
  make "${MAKE_ARGS[@]}" operator-sdk
  ./bin/operator-sdk run bundle "${BUNDLE_IMG}" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --decompression-image "${OLM_DECOMPRESSION_IMAGE}"
  echo "Bundle installed in namespace ${OPERATOR_NAMESPACE}"
fi
