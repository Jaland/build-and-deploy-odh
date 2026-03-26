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
# Optional MaaS / models-as-a-service manifests (upstream get_all_manifests.sh supports --maas=...):
#   MAAS_MANIFEST_REF   If set, override the maas component (e.g. main, rhoai-3.4, or main@<sha>).
#                       Use main for the branch tip; see MAAS_MANIFEST_PIN_LATEST for pinning.
#   MAAS_MANIFEST_PIN_LATEST  If 1/true and MAAS_MANIFEST_REF is main, resolve to main@<current_sha>.
#   MAAS_MANIFEST_ORG   GitHub org (default: opendatahub-io)
#   MAAS_MANIFEST_REPO  Repo name (default: maas-billing; use models-as-a-service or another fork if needed)
#   MAAS_MANIFEST_SOURCE_PATH  Path inside repo (default: deployment)
#   ODH_PLATFORM_TYPE   OpenDataHub (default) or rhoai — selects which base manifest map is used before override
#   MAAS_MANIFEST_WRITE_FILE  If 1, rewrite the ["maas"]= line in get_all_manifests.sh to match the override
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

maas_override=""

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

export ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE:-OpenDataHub}"
MAKE_ARGS=(IMAGE_TAG_BASE="${IMAGE_TAG_BASE}" IMG_TAG="${IMG_TAG}" ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}")
if [[ -n "${VERSION:-}" ]]; then
  MAKE_ARGS+=(VERSION="${VERSION}")
fi

# Upstream: https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh
# Optional --maas=org:repo:ref:path overrides the pinned maas-billing (or other) revision without editing the file.
resolve_branch_head_sha() {
  local org="$1" repo="$2" branch="$3"
  git ls-remote "https://github.com/${org}/${repo}.git" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}'
}

build_maas_manifest_override() {
  local org="${MAAS_MANIFEST_ORG:-opendatahub-io}"
  local repo="${MAAS_MANIFEST_REPO:-maas-billing}"
  local path="${MAAS_MANIFEST_SOURCE_PATH:-deployment}"
  local ref="${MAAS_MANIFEST_REF:-}"
  [[ -n "${ref}" ]] || return 1
  if [[ "${MAAS_MANIFEST_PIN_LATEST:-}" == "1" || "${MAAS_MANIFEST_PIN_LATEST:-}" == "true" ]]; then
    if [[ "${ref}" != "main" ]]; then
      echo "ERROR: MAAS_MANIFEST_PIN_LATEST requires MAAS_MANIFEST_REF=main" >&2
      exit 1
    fi
    local sha
    sha="$(resolve_branch_head_sha "${org}" "${repo}" "main")"
    if [[ -z "${sha}" ]]; then
      echo "ERROR: could not resolve latest commit for https://github.com/${org}/${repo} branch main" >&2
      exit 1
    fi
    echo "${ref}@${sha}"
  else
    echo "${ref}"
  fi
}

maybe_patch_get_all_manifests_file() {
  local override="$1"
  if [[ "${MAAS_MANIFEST_WRITE_FILE:-}" != "1" && "${MAAS_MANIFEST_WRITE_FILE:-}" != "true" ]]; then
    return 0
  fi
  local f="get_all_manifests.sh"
  [[ -f "${f}" ]] || return 0
  echo "Rewriting [\"maas\"] lines in ${f} (MAAS_MANIFEST_WRITE_FILE=1)..."
  # ODH and RHOAI blocks both define ["maas"]; replace the value inside the quotes.
  MAAS_OVERRIDE="$override" perl -i -pe 's/^(\s*\["maas"\]=")[^"]+/$1$ENV{MAAS_OVERRIDE}/' "${f}"
}

if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
  echo "Fetching component manifests (get_all_manifests.sh)..."
  if [[ -n "${MAAS_MANIFEST_REF:-}" ]]; then
    ref_resolved="$(build_maas_manifest_override)"
    org="${MAAS_MANIFEST_ORG:-opendatahub-io}"
    repo="${MAAS_MANIFEST_REPO:-maas-billing}"
    path="${MAAS_MANIFEST_SOURCE_PATH:-deployment}"
    maas_override="${org}:${repo}:${ref_resolved}:${path}"
    echo "MaaS manifest override: --maas=${maas_override}"
    maybe_patch_get_all_manifests_file "${maas_override}"
  fi
  VERSION_FOR_MANIFESTS="$(make "${MAKE_ARGS[@]}" -s print-VERSION 2>/dev/null || true)"
  ga_args=()
  [[ -n "${maas_override}" ]] && ga_args+=(--maas="${maas_override}")
  ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}" VERSION="${VERSION_FOR_MANIFESTS}" ./get_all_manifests.sh "${ga_args[@]}"
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
  echo "MAAS_OVERRIDE=${maas_override:-}"
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
