#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker; set IMAGE_BUILDER=docker for make.
#
# Builds and pushes the Open Data Hub operator image, OLM bundle, and FBC catalog
# from https://github.com/opendatahub-io/opendatahub-operator
#
# Required env:
#   IMAGE_TAG_BASE  Full image path without tag for the operator image, e.g. quay.io/myorg/opendatahub-operator
#   QUAY_USERNAME   Registry user (registry login; same creds for operator, bundle, catalog)
#   QUAY_PASSWORD   Registry password or robot token
#
# Optional env:
#   BUNDLE_REPO     Separate OLM bundle image path without tag (e.g. quay.io/myorg/odh-operator-bundle).
#                   If unset, bundle is ${IMAGE_TAG_BASE}-bundle:v$VERSION (upstream default).
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
#   MANIFEST_ARTIFACT_DIR  After get-manifests, copies get_all_manifests.sh + maas-fetch-effective.txt here
#                       (default: <repo>/manifest-validation) for CI artifacts / local inspection.
#
# Optional MaaS manifests (upstream get_all_manifests.sh supports --maas=...):
#   By default this script passes --maas=opendatahub-io:maas-billing:main:deployment so ODH ["maas"] tracks
#   https://github.com/opendatahub-io/maas-billing branch main (path deployment/), matching a main-only map line.
#   MAAS_MANIFEST_USE_UPSTREAM_PIN  If 1/true, do NOT pass --maas=; use the ["maas"] pin baked into upstream
#                       get_all_manifests.sh (e.g. main@sha) instead.
#   MAAS_MANIFEST_REF   Branch or ref (default: main). Use main@<sha> for a fixed commit.
#   MAAS_MANIFEST_PIN_LATEST  If 1/true with MAAS_MANIFEST_REF=main, pass main@<sha> where sha is from git ls-remote
#                       at script start (reproducible snapshot of main for that run).
#   Before ./get_all_manifests.sh, the ODH ["maas"] line in get_all_manifests.sh is rewritten on disk to match
#   the same org:repo:ref:path as --maas= (only lines with value starting opendatahub-io: — RHOAI block unchanged).
#   MAAS_MANIFEST_SKIP_FILE_PATCH  If 1/true, skip that rewrite (CLI --maas= only).
#   MaaS --maas=org:repo:ref:path (see upstream get_all_manifests.sh). Defaults:
#   MAAS_MANIFEST_ORG         opendatahub-io
#   MAAS_MANIFEST_REPO        maas-billing
#   MAAS_MANIFEST_REF         main   (branch, tag, or main@sha)
#   MAAS_MANIFEST_SOURCE_PATH deployment
#   ODH_PLATFORM_TYPE   OpenDataHub (default) or rhoai — selects which base manifest map is used before override
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
MAAS_RESOLVED_REF=""

# Log in once per registry host (operator/bundle and optional catalog may use different repos or hosts).
login_registry_hosts() {
  local host
  while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    echo "Logging in to ${host}..."
    echo "${QUAY_PASSWORD}" | "${IMAGE_BUILDER}" login "${host}" -u "${QUAY_USERNAME}" --password-stdin
  done < <(for ref in "$@"; do [[ -z "${ref}" ]] && continue; echo "${ref%%/*}"; done | sort -u)
}
login_registry_hosts "${IMAGE_TAG_BASE}" "${BUNDLE_REPO:-}" "${CATALOG_REPO:-}"

export IMAGE_BUILDER

export ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE:-OpenDataHub}"
MAKE_ARGS=(IMAGE_TAG_BASE="${IMAGE_TAG_BASE}" IMG_TAG="${IMG_TAG}" ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}")
if [[ -n "${VERSION:-}" ]]; then
  MAKE_ARGS+=(VERSION="${VERSION}")
fi

# Upstream: https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh
# Optional --maas=org:repo:ref:path overrides the default opendatahub-io:maas-billing:main:deployment.
resolve_branch_head_sha() {
  local org="$1" repo="$2" branch="$3"
  git ls-remote "https://github.com/${org}/${repo}.git" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}'
}

build_maas_manifest_override() {
  local org="${MAAS_MANIFEST_ORG:-opendatahub-io}"
  local repo="${MAAS_MANIFEST_REPO:-maas-billing}"
  local path="${MAAS_MANIFEST_SOURCE_PATH:-deployment}"
  local ref="${MAAS_MANIFEST_REF:-main}"
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

apply_maas_line_to_get_all_manifests_file() {
  local override="$1"
  if [[ "${MAAS_MANIFEST_SKIP_FILE_PATCH:-}" == "1" || "${MAAS_MANIFEST_SKIP_FILE_PATCH:-}" == "true" ]]; then
    echo "NOTE: MAAS_MANIFEST_SKIP_FILE_PATCH=1 — leaving get_all_manifests.sh [\"maas\"] lines unchanged on disk."
    return 0
  fi
  local f="get_all_manifests.sh"
  [[ -f "${f}" ]] || return 0
  echo "Rewriting ODH [\"maas\"] line in ${f} on disk to match --maas= (${override})..."
  # Only the Open Data Hub map line uses org opendatahub-io: — do not replace red-hat-data-services: (RHOAI).
  MAAS_OVERRIDE="$override" perl -i -pe 's/^(\s*\["maas"\]=")opendatahub-io:[^"]+/$1$ENV{MAAS_OVERRIDE}/' "${f}"
}

validate_maas_manifests() {
  [[ -z "${maas_override:-}" ]] && return 0
  local d="opt/manifests/maas"
  if [[ ! -d "${d}" ]]; then
    echo "ERROR: MaaS override was used but ${d} is missing after get_all_manifests.sh" >&2
    exit 1
  fi
  local n
  n="$(find "${d}" -type f 2>/dev/null | wc -l)"
  if [[ "${n}" -lt 1 ]]; then
    echo "ERROR: ${d} exists but contains no files (MaaS fetch may have failed)" >&2
    exit 1
  fi
  echo "Validated MaaS manifests: ${d} (${n} file(s)); ref: ${MAAS_RESOLVED_REF:-unknown}"
}

if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
  echo "Fetching component manifests (get_all_manifests.sh)..."
  if [[ "${MAAS_MANIFEST_USE_UPSTREAM_PIN:-}" == "1" || "${MAAS_MANIFEST_USE_UPSTREAM_PIN:-}" == "true" ]]; then
    echo "NOTE: MAAS_MANIFEST_USE_UPSTREAM_PIN=1 — using the [\"maas\"] pin in upstream get_all_manifests.sh (not --maas=opendatahub-io:maas-billing:main:deployment)."
  else
    ref_resolved="$(build_maas_manifest_override)"
    MAAS_RESOLVED_REF="${ref_resolved}"
    org="${MAAS_MANIFEST_ORG:-opendatahub-io}"
    repo="${MAAS_MANIFEST_REPO:-maas-billing}"
    path="${MAAS_MANIFEST_SOURCE_PATH:-deployment}"
    maas_override="${org}:${repo}:${ref_resolved}:${path}"
    echo "MaaS manifests: https://github.com/${org}/${repo} @ ${ref_resolved} (path: ${path}/) — --maas=${maas_override}"
    apply_maas_line_to_get_all_manifests_file "${maas_override}"
  fi
  VERSION_FOR_MANIFESTS="$(make "${MAKE_ARGS[@]}" -s print-VERSION 2>/dev/null || true)"
  ga_args=()
  [[ -n "${maas_override}" ]] && ga_args+=(--maas="${maas_override}")
  ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}" VERSION="${VERSION_FOR_MANIFESTS}" ./get_all_manifests.sh "${ga_args[@]}"
  validate_maas_manifests
  # Copy upstream manifest map + effective --maas for validation (CI uploads manifest-validation/ as an artifact).
  MANIFEST_ARTIFACT_DIR="${MANIFEST_ARTIFACT_DIR:-${ROOT}/manifest-validation}"
  mkdir -p "${MANIFEST_ARTIFACT_DIR}"
  if [[ -f get_all_manifests.sh ]]; then
    cp -f get_all_manifests.sh "${MANIFEST_ARTIFACT_DIR}/get_all_manifests.sh"
  fi
  {
    echo "# Generated by build-and-push-odh-operator.sh — effective MaaS fetch for this build."
    echo "# Unless MAAS_MANIFEST_SKIP_FILE_PATCH=1, get_all_manifests.sh was rewritten so ODH [\"maas\"] matches --maas=."
    echo "OPERATOR_GIT_REF=${OPERATOR_GIT_REF}"
    echo "ODH_PLATFORM_TYPE=${ODH_PLATFORM_TYPE}"
    if [[ -n "${maas_override:-}" ]]; then
      echo "MAAS_OVERRIDE=${maas_override}"
      echo "GET_ALL_MANIFESTS_ARG=--maas=${maas_override}"
    else
      echo "MAAS_OVERRIDE="
      echo "GET_ALL_MANIFESTS_ARG=(none — MAAS_MANIFEST_USE_UPSTREAM_PIN=1; upstream [\"maas\"] in get_all_manifests.sh applies)"
    fi
  } > "${MANIFEST_ARTIFACT_DIR}/maas-fetch-effective.txt"
  echo "Manifest validation artifacts: ${MANIFEST_ARTIFACT_DIR}/ (get_all_manifests.sh, maas-fetch-effective.txt)"
else
  echo "Skipping get-manifests"
fi

echo "Building and pushing operator image..."
make "${MAKE_ARGS[@]}" image

VERSION_RESOLVED="$(make "${MAKE_ARGS[@]}" -s print-VERSION)"
if [[ -n "${BUNDLE_REPO:-}" ]]; then
  BUNDLE_IMG="${BUNDLE_REPO}:v${VERSION_RESOLVED}"
else
  BUNDLE_IMG="${IMAGE_TAG_BASE}-bundle:v${VERSION_RESOLVED}"
fi
if [[ -n "${CATALOG_REPO:-}" ]]; then
  CATALOG_IMG="${CATALOG_REPO}:v${VERSION_RESOLVED}"
else
  CATALOG_IMG="${IMAGE_TAG_BASE}-catalog:v${VERSION_RESOLVED}"
fi

echo "Building and pushing bundle image (${BUNDLE_IMG})..."
make "${MAKE_ARGS[@]}" BUNDLE_IMG="${BUNDLE_IMG}" bundle-build bundle-push

echo "Building and pushing catalog image (${CATALOG_IMG})..."
make "${MAKE_ARGS[@]}" BUNDLE_IMGS="${BUNDLE_IMG}" CATALOG_IMG="${CATALOG_IMG}" catalog-build catalog-push

OPERATOR_IMG="${IMAGE_TAG_BASE}:${IMG_TAG}"

# OLM Subscription startingCSV must match the ClusterServiceVersion name in this bundle (see bundle metadata).
case "${ODH_PLATFORM_TYPE:-OpenDataHub}" in
  rhoai|RHOAI) OPERATOR_CSV_PACKAGE="rhods-operator" ;;
  *) OPERATOR_CSV_PACKAGE="opendatahub-operator" ;;
esac
OPERATOR_STARTING_CSV="${OPERATOR_CSV_PACKAGE}.v${VERSION_RESOLVED}"

# Models-as-a-Service: https://github.com/opendatahub-io/maas-billing/blob/main/scripts/deploy.sh
# deploy.sh reads OPERATOR_STARTING_CSV from the environment (not a flag); optional "-" omits startingCSV.
# --channel must match the channel name in the built catalog (upstream FBC uses "fast", not derived from VERSION).
# "fast-3" is an OperatorHub/community naming path; standard make catalog-build stays on "fast".
MAAS_DEPLOY_COMMAND="OPERATOR_STARTING_CSV='${OPERATOR_STARTING_CSV}' ./scripts/deploy.sh --operator-catalog ${CATALOG_IMG} --operator-image ${OPERATOR_IMG} --channel fast"
MAAS_DEPLOY_SNIPPET="# OLM bundle image (indexed by the catalog above): ${BUNDLE_IMG}
# Subscription startingCSV (matches bundle CSV): ${OPERATOR_STARTING_CSV}
${MAAS_DEPLOY_COMMAND}"

{
  echo "OPERATOR_IMAGE=${OPERATOR_IMG}"
  echo "BUNDLE_IMAGE=${BUNDLE_IMG}"
  echo "CATALOG_IMAGE=${CATALOG_IMG}"
  echo "IMAGE_TAG_BASE=${IMAGE_TAG_BASE}"
  echo "BUNDLE_REPO=${BUNDLE_REPO:-}"
  echo "CATALOG_REPO=${CATALOG_REPO:-}"
  echo "MAAS_OVERRIDE=${maas_override:-}"
  echo "MAAS_MANIFEST_RESOLVED_REF=${MAAS_RESOLVED_REF:-}"
  echo "IMG_TAG=${IMG_TAG}"
  echo "VERSION=${VERSION_RESOLVED}"
  echo "OPERATOR_STARTING_CSV=${OPERATOR_STARTING_CSV}"
  if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
    echo "MANIFEST_VALIDATION_DIR=${MANIFEST_ARTIFACT_DIR:-}"
  fi
  # Shell-quote so `source build-output.env` does not treat --flags as commands
  printf 'MAAS_DEPLOY_COMMAND=%q\n' "${MAAS_DEPLOY_COMMAND}"
  printf 'MAAS_DEPLOY_SNIPPET=%q\n' "${MAAS_DEPLOY_SNIPPET}"
} | tee "$BUILD_OUTPUT_ENV"

echo ""
echo "========== Build complete =========="
echo "Operator image: ${OPERATOR_IMG}"
echo "Bundle image:   ${BUNDLE_IMG}"
echo "Catalog image:  ${CATALOG_IMG}"
echo "===================================="
echo ""
echo "MaaS / Models-as-a-Service deploy (from a maas-billing clone):"
echo "  # OLM bundle image (indexed by catalog): ${BUNDLE_IMG}"
echo "  # startingCSV: ${OPERATOR_STARTING_CSV}"
echo "  ${MAAS_DEPLOY_COMMAND}"
echo "Docs: https://opendatahub-io.github.io/models-as-a-service/latest/install/maas-setup/"

if [[ "${DEPLOY_BUNDLE}" == "1" ]]; then
  echo "Deploying bundle to cluster (operator-sdk run bundle)..."
  make "${MAKE_ARGS[@]}" operator-sdk
  ./bin/operator-sdk run bundle "${BUNDLE_IMG}" \
    --namespace "${OPERATOR_NAMESPACE}" \
    --decompression-image "${OLM_DECOMPRESSION_IMAGE}"
  echo "Bundle installed in namespace ${OPERATOR_NAMESPACE}"
fi
