#!/usr/bin/env bash
# Container runtime: Podman (Docker compatible)
# Replace 'podman' with 'docker' if using Docker; set IMAGE_BUILDER=docker for make.
#
# Builds and pushes the Open Data Hub operator image, OLM bundle, and FBC catalog
# from https://github.com/opendatahub-io/opendatahub-operator
#
# Required env:
#   IMAGE_TAG_BASE  Full image path without tag for the operator image (default: quay.io/maas/opendatahub-operator)
#   QUAY_USERNAME   Registry user (optional if already logged in via podman/docker login)
#   QUAY_PASSWORD   Registry password or robot token (optional with existing login)
#
# Optional env:
#   BUNDLE_REPO     Separate OLM bundle image path without tag (e.g. quay.io/myorg/odh-operator-bundle).
#                   If unset, bundle is ${IMAGE_TAG_BASE}-bundle:v$VERSION (upstream default).
#   CATALOG_REPO    Separate catalog image path without tag (e.g. quay.io/myorg/odh-catalog-index).
#                   If unset, catalog is ${IMAGE_TAG_BASE}-catalog:v$VERSION (upstream default).
#   IMG_TAG           Operator image tag (default: latest)
#   UNIFIED_IMAGE_TAG If set, use one tag for operator, bundle, and catalog (overrides IMG_TAG; replaces bundle/catalog
#                     v$VERSION tags). The script sets Makefile VERSION from this tag so CSV and file-based catalog match:
#                     use vX.Y.Z or X.Y.Z (e.g. v3.4.0 or 3.4.0). Bare semver is normalized to vX.Y.Z on images.
#                     Upstream hack/update-catalog-template.sh names bundles from the image tag; it must match CSV name
#                     opendatahub-operator.vX.Y.Z. Do not set VERSION separately unless you omit UNIFIED_IMAGE_TAG.
#   VERSION           OLM bundle/catalog version for Makefile and CSV (Makefile default if unset). Ignored when
#                     UNIFIED_IMAGE_TAG is set (derived from the unified tag). Image tags default to v$VERSION for
#                     bundle/catalog unless UNIFIED_IMAGE_TAG is set.
#   OPERATOR_GIT_REF  Branch, tag, or commit to build (default: main)
#   OPERATOR_REPO_URL Clone URL (default: upstream GitHub)
#   CLONE_DIR         Where to clone the operator repo (default: ./opendatahub-operator)
#   SKIP_GET_MANIFESTS  If 1, skip make get-manifests (not recommended for release-like builds)
#   DEPLOY_BUNDLE     If 1, run operator-sdk run bundle after push (needs oc/kubectl + kubeconfig)
#   OPERATOR_NAMESPACE Namespace for bundle install (default: opendatahub-operator-system)
#   OLM_DECOMPRESSION_IMAGE Image for operator-sdk bundle unpack (default from upstream README)
#   IMAGE_BUILDER     podman or docker (default: podman)
#   GOPROXY / GOSUMDB     Go module proxy and checksum DB (defaults: proxy.golang.org, sum.golang.org).
#                         Set GOSUMDB=off if sum.golang.org is unreachable from your network.
#   BUNDLE_BUILD_NO_CACHE If 1, keep upstream bundle-build --no-cache (default: allow layer cache).
#   MAKE_RETRY_ATTEMPTS   Retries for bundle-build on transient network errors (default: 3).
#
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
#   MAAS_REPO_URL           Simplified MaaS source: GitHub HTTPS URL (sets org/repo; use with MAAS_GIT_REF).
#   MAAS_GIT_REF            Branch or ref for MAAS (default main when MAAS_REPO_URL is set).
#   MAAS_SOURCE_PATH        Folder in MaaS repo (default deployment). Used with MAAS_REPO_URL.
#   MAAS_MANIFEST_REPO_URL    Optional GitHub HTTPS URL for the MaaS repo (e.g. https://github.com/org/models-as-a-service).
#                             If set, MAAS_MANIFEST_ORG and MAAS_MANIFEST_REPO are derived from it (overrides those env vars).
#                             Upstream get_all_manifests.sh clones from github.com only.
#   AI Gateway (module operator manifests + optional built image):
#   AI_GATEWAY_REPO_URL     Clone URL for ai-gateway-operator (default upstream).
#   AI_GATEWAY_GIT_REF      Branch/tag/commit for --aigateway= override (default main).
#   AI_GATEWAY_IMAGE        Full image ref for the module operator (patches opt/manifests/aigateway/manager/kustomization.yaml).
#                             Set automatically when using build-odh-stack.sh after the AI Gateway image build.
#   DASHBOARD_USE_MAIN       If 1/true, fetch ODH dashboard from branch main (opendatahub-io:odh-dashboard:main:manifests).
#                            Rewrites ODH ["dashboard"] in get_all_manifests.sh and passes --dashboard=... (OpenDataHub only).
#   ODH_PLATFORM_TYPE   OpenDataHub (default) or rhoai — selects which base manifest map is used before override
#
# Optional MaaS workload images (after get_all_manifests.sh; rewrites kustomize images: in fetched manifests):
#   MAAS_CONTROLLER_IMAGE  Full container reference for the maas-controller operand, e.g. quay.io/myorg/maas-controller:v1.2.3
#                        or quay.io/myorg/maas-controller@sha256:... (digest replaces newTag in kustomization).
#                        Parsed as repository:tag when the last ':' is after the last '/' (supports registry:5000/repo:tag).
#                        If there is no tag segment, newTag defaults to latest. Requires opt/manifests/maas/base/... layout.
#   MAAS_API_IMAGE         Same for the maas-api operand (patches base/maas-api/core/kustomization.yaml).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/component-ref.sh
source "${SCRIPT_DIR}/lib/component-ref.sh"

ensure_go_toolchain
IMG_TAG="${IMG_TAG:-latest}"
resolve_unified_image_tag
OPERATOR_GIT_REF="${OPERATOR_GIT_REF:-main}"
OPERATOR_REPO_URL="${OPERATOR_REPO_URL:-https://github.com/opendatahub-io/opendatahub-operator.git}"
CLONE_DIR="${CLONE_DIR:-./opendatahub-operator}"
SKIP_GET_MANIFESTS="${SKIP_GET_MANIFESTS:-0}"
DEPLOY_BUNDLE="${DEPLOY_BUNDLE:-0}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-opendatahub-operator-system}"
IMAGE_BUILDER="${IMAGE_BUILDER:-podman}"
OLM_DECOMPRESSION_IMAGE="${OLM_DECOMPRESSION_IMAGE:-quay.io/project-codeflare/busybox:1.36}"

IMAGE_TAG_BASE="${IMAGE_TAG_BASE:-${QUAY_REPO:-quay.io/maas/opendatahub-operator}}"

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

prepare_operator_go_build "$(pwd)"

maas_override=""
MAAS_RESOLVED_REF=""
aigateway_override=""
AI_GATEWAY_IMAGE_EFFECTIVE=""
dashboard_override=""
MAAS_CONTROLLER_IMAGE_EFFECTIVE=""
MAAS_API_IMAGE_EFFECTIVE=""

login_registry_hosts "${IMAGE_BUILDER}" "${QUAY_USERNAME:-}" "${QUAY_PASSWORD:-}" \
  "${IMAGE_TAG_BASE}" "${BUNDLE_REPO:-}" "${CATALOG_REPO:-}"

export IMAGE_BUILDER

export ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE:-OpenDataHub}"
MAKE_ARGS=(IMAGE_TAG_BASE="${IMAGE_TAG_BASE}" IMG_TAG="${IMG_TAG}" ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}")
if [[ -n "${VERSION:-}" ]]; then
  MAKE_ARGS+=(VERSION="${VERSION}")
fi

# Upstream: https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh
# Optional --maas=org:repo:ref:path overrides the default opendatahub-io:maas-billing:main:deployment.

# Simplified MAAS_REPO_URL + MAAS_GIT_REF, or legacy MAAS_MANIFEST_REPO_URL / MAAS_MANIFEST_* .
apply_maas_manifest_repo_url() {
  local url="${MAAS_REPO_URL:-${MAAS_MANIFEST_REPO_URL:-}}"
  [[ -z "${url}" ]] && return 0
  if parse_github_repo_url "${url}"; then
    export MAAS_MANIFEST_ORG="${GITHUB_ORG}"
    export MAAS_MANIFEST_REPO="${GITHUB_REPO}"
    echo "MaaS repo URL ${url} → MAAS_MANIFEST_ORG=${MAAS_MANIFEST_ORG} MAAS_MANIFEST_REPO=${MAAS_MANIFEST_REPO}"
  else
    exit 1
  fi
}

build_aigateway_manifest_override() {
  local url="${AI_GATEWAY_REPO_URL:-https://github.com/opendatahub-io/ai-gateway-operator.git}"
  local ref="${AI_GATEWAY_GIT_REF:-main}"
  if ! parse_github_repo_url "${url}"; then
    exit 1
  fi
  build_component_override "${GITHUB_ORG}" "${GITHUB_REPO}" "${ref}" "config"
}

apply_aigateway_line_to_get_all_manifests_file() {
  local override="$1"
  local f="get_all_manifests.sh"
  [[ -f "${f}" ]] || return 0
  echo "Rewriting ODH [\"aigateway\"] line in ${f} on disk to match --aigateway= (${override})..."
  AIGATEWAY_OVERRIDE="$override" perl -i -pe 's/^(\s*\["aigateway"\]=")opendatahub-io:[^"]+/$1$ENV{AIGATEWAY_OVERRIDE}/' "${f}"
}

build_maas_manifest_override() {
  local org="${MAAS_MANIFEST_ORG:-opendatahub-io}"
  local repo="${MAAS_MANIFEST_REPO:-maas-billing}"
  local path="${MAAS_SOURCE_PATH:-${MAAS_MANIFEST_SOURCE_PATH:-deployment}}"
  local ref="${MAAS_GIT_REF:-${MAAS_MANIFEST_REF:-main}}"
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

# Upstream ODH map: ["dashboard"]="opendatahub-io:odh-dashboard:<ref>:manifests" (see get_all_manifests.sh).
apply_dashboard_line_to_get_all_manifests_file() {
  local override="$1"
  local f="get_all_manifests.sh"
  [[ -f "${f}" ]] || return 0
  echo "Rewriting ODH [\"dashboard\"] line in ${f} on disk to match --dashboard= (${override})..."
  DASHBOARD_OVERRIDE="$override" perl -i -pe 's/^(\s*\["dashboard"\]=")opendatahub-io:[^"]+/$1$ENV{DASHBOARD_OVERRIDE}/' "${f}"
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

validate_dashboard_manifests() {
  [[ -z "${dashboard_override:-}" ]] && return 0
  local d="opt/manifests/dashboard"
  if [[ ! -d "${d}" ]]; then
    echo "ERROR: DASHBOARD_USE_MAIN was used but ${d} is missing after get_all_manifests.sh" >&2
    exit 1
  fi
  local n
  n="$(find "${d}" -type f 2>/dev/null | wc -l)"
  if [[ "${n}" -lt 1 ]]; then
    echo "ERROR: ${d} exists but contains no files (dashboard fetch may have failed)" >&2
    exit 1
  fi
  echo "Validated dashboard manifests: ${d} (${n} file(s))"
}

apply_aigateway_image_override() {
  local image="${AI_GATEWAY_IMAGE:-}"
  [[ -z "${image}" ]] && return 0
  local kust="opt/manifests/aigateway/manager/kustomization.yaml"
  [[ -f "${kust}" ]] || {
    echo "ERROR: AI_GATEWAY_IMAGE set but missing ${kust} after get_all_manifests.sh" >&2
    exit 1
  }
  AI_GATEWAY_IMAGE_EFFECTIVE="${image}"
  _AIGW_KUST="${kust}" _AIGW_IMG="${image}" python3 - <<'PY'
import os, pathlib, re, sys

def parse_ref(s: str):
    s = (s or "").strip()
    if not s:
        return None
    if "@" in s:
        base, _, qual = s.rpartition("@")
        if qual.startswith(("sha256:", "sha512:")):
            return (base, None, qual)
    slash = s.rfind("/")
    colon = s.rfind(":")
    if colon > slash:
        return (s[:colon], s[colon + 1 :], None)
    return (s, "latest", None)

path = pathlib.Path(os.environ["_AIGW_KUST"])
parsed = parse_ref(os.environ["_AIGW_IMG"])
if not parsed:
    sys.exit(1)
new_name, new_tag, digest = parsed
text = path.read_text()
pat = re.compile(
    r"^([ \t]*- name: controller\n)((?:[ \t]+(?:newName|newTag|digest):[^\n]+\n)+)",
    re.MULTILINE,
)
m = pat.search(text)
if not m:
    print(f"ERROR: could not find images: entry '- name: controller' in {path}", file=sys.stderr)
    sys.exit(1)
head = m.group(1)
ind_m = re.search(r"^([ \t]+)newName:", m.group(2), re.MULTILINE)
ind = ind_m.group(1) if ind_m else "  "
if digest:
    block = f"{head}{ind}newName: {new_name}\n{ind}digest: {digest}\n"
else:
    block = f"{head}{ind}newName: {new_name}\n{ind}newTag: {new_tag}\n"
path.write_text(text[: m.start()] + block + text[m.end() :])
print(f"Patched AI Gateway operator image in {path} ← {os.environ['_AIGW_IMG']!r}")
PY
}

# Patch models-as-a-service kustomize image newName/newTag (or digest) under opt/manifests/maas/ (see MAAS_*_IMAGE env).
apply_maas_component_image_overrides() {
  local maas_root="opt/manifests/maas"
  [[ -d "${maas_root}" ]] || return 0
  local ctrl="${MAAS_CONTROLLER_IMAGE:-}"
  local api="${MAAS_API_IMAGE:-}"
  [[ -z "${ctrl}" && -z "${api}" ]] && return 0
  MAAS_CONTROLLER_IMAGE_EFFECTIVE="${ctrl}"
  MAAS_API_IMAGE_EFFECTIVE="${api}"
  _MAAS_ROOT="${maas_root}" _MAAS_CTRL_IMG="${ctrl}" _MAAS_API_IMG="${api}" python3 - <<'PY'
import os, pathlib, re, sys

def parse_ref(s: str):
    s = (s or "").strip()
    if not s:
        return None
    if "@" in s:
        base, _, qual = s.rpartition("@")
        if qual.startswith(("sha256:", "sha512:")):
            return (base, None, qual)
    slash = s.rfind("/")
    colon = s.rfind(":")
    if colon > slash:
        return (s[:colon], s[colon + 1 :], None)
    return (s, "latest", None)

def patch_images_block(text: str, logical: str, parsed) -> str:
    if not parsed:
        return text
    new_name, new_tag, digest = parsed
    pat = re.compile(
        rf"^([ \t]*- name: {re.escape(logical)}\n)((?:[ \t]+(?:newName|newTag|digest):[^\n]+\n)+)",
        re.MULTILINE,
    )
    m = pat.search(text)
    if not m:
        return None
    head = m.group(1)
    inner = m.group(2)
    ind_m = re.search(r"^([ \t]+)newName:", inner, re.MULTILINE)
    ind = ind_m.group(1) if ind_m else "  "
    if digest:
        block = f"{head}{ind}newName: {new_name}\n{ind}digest: {digest}\n"
    else:
        block = f"{head}{ind}newName: {new_name}\n{ind}newTag: {new_tag}\n"
    return text[: m.start()] + block + text[m.end() :]

root = pathlib.Path(os.environ["_MAAS_ROOT"])
jobs = [
    (root / "base/maas-controller/manager/kustomization.yaml", "maas-controller", os.environ.get("_MAAS_CTRL_IMG", "")),
    (root / "base/maas-api/core/kustomization.yaml", "maas-api", os.environ.get("_MAAS_API_IMG", "")),
]
for path, logical, ref in jobs:
    ref = (ref or "").strip()
    if not ref:
        continue
    parsed = parse_ref(ref)
    if not path.is_file():
        print(f"ERROR: MAAS_*_IMAGE set but missing file: {path}", file=sys.stderr)
        sys.exit(1)
    raw = path.read_text()
    updated = patch_images_block(raw, logical, parsed)
    if updated is None:
        print(
            f"ERROR: could not find images: entry '- name: {logical}' in {path} (MaaS layout changed?)",
            file=sys.stderr,
        )
        sys.exit(1)
    path.write_text(updated)
    print(f"Patched MaaS operand image {logical} in {path} ← {ref!r}")
PY
}

if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
  echo "Fetching component manifests (get_all_manifests.sh)..."
  apply_maas_manifest_repo_url
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
  if [[ -n "${AI_GATEWAY_REPO_URL:-}" || -n "${AI_GATEWAY_GIT_REF:-}" || -n "${AI_GATEWAY_IMAGE:-}" ]]; then
    aigateway_override="$(build_aigateway_manifest_override)"
    echo "AI Gateway manifests: --aigateway=${aigateway_override}"
    apply_aigateway_line_to_get_all_manifests_file "${aigateway_override}"
  fi
  if [[ "${DASHBOARD_USE_MAIN:-}" == "1" || "${DASHBOARD_USE_MAIN:-}" == "true" ]]; then
    if [[ "${ODH_PLATFORM_TYPE:-OpenDataHub}" != "OpenDataHub" ]]; then
      echo "NOTE: DASHBOARD_USE_MAIN is set but ODH_PLATFORM_TYPE is not OpenDataHub — skipping dashboard main override (RHOAI uses red-hat-data-services pins)."
    else
      dashboard_override="opendatahub-io:odh-dashboard:main:manifests"
      echo "Dashboard manifests: https://github.com/opendatahub-io/odh-dashboard @ main (path: manifests/) — --dashboard=${dashboard_override}"
      apply_dashboard_line_to_get_all_manifests_file "${dashboard_override}"
    fi
  fi
  VERSION_FOR_MANIFESTS="$(make "${MAKE_ARGS[@]}" -s print-VERSION 2>/dev/null || true)"
  ga_args=()
  [[ -n "${maas_override}" ]] && ga_args+=(--maas="${maas_override}")
  [[ -n "${aigateway_override}" ]] && ga_args+=(--aigateway="${aigateway_override}")
  [[ -n "${dashboard_override}" ]] && ga_args+=(--dashboard="${dashboard_override}")
  ODH_PLATFORM_TYPE="${ODH_PLATFORM_TYPE}" VERSION="${VERSION_FOR_MANIFESTS}" ./get_all_manifests.sh "${ga_args[@]}"
  apply_aigateway_image_override
  apply_maas_component_image_overrides
  validate_maas_manifests
  validate_dashboard_manifests
  # Copy upstream manifest map + effective --maas for validation (CI uploads manifest-validation/ as an artifact).
  MANIFEST_ARTIFACT_DIR="${MANIFEST_ARTIFACT_DIR:-${ROOT}/manifest-validation}"
  mkdir -p "${MANIFEST_ARTIFACT_DIR}"
  if [[ -f get_all_manifests.sh ]]; then
    cp -f get_all_manifests.sh "${MANIFEST_ARTIFACT_DIR}/get_all_manifests.sh"
  fi
  {
    echo "# Generated by build-and-push-odh-operator.sh — effective get_all_manifests overrides for this build."
    echo "# Unless MAAS_MANIFEST_SKIP_FILE_PATCH=1, get_all_manifests.sh was rewritten so ODH [\"maas\"] matches --maas=."
    echo "# When DASHBOARD_USE_MAIN=1, ODH [\"dashboard\"] was rewritten to opendatahub-io:odh-dashboard:main:manifests."
    echo "OPERATOR_REPO_URL=${OPERATOR_REPO_URL:-}"
    echo "OPERATOR_GIT_REF=${OPERATOR_GIT_REF}"
    echo "AI_GATEWAY_REPO_URL=${AI_GATEWAY_REPO_URL:-}"
    echo "AI_GATEWAY_GIT_REF=${AI_GATEWAY_GIT_REF:-}"
    echo "AI_GATEWAY_IMAGE_EFFECTIVE=${AI_GATEWAY_IMAGE_EFFECTIVE:-}"
    echo "MAAS_REPO_URL=${MAAS_REPO_URL:-${MAAS_MANIFEST_REPO_URL:-}}"
    echo "MAAS_GIT_REF=${MAAS_GIT_REF:-${MAAS_MANIFEST_REF:-}}"
    echo "MAAS_MANIFEST_REPO_URL=${MAAS_MANIFEST_REPO_URL:-}"
    echo "MAAS_MANIFEST_ORG=${MAAS_MANIFEST_ORG:-}"
    echo "MAAS_MANIFEST_REPO=${MAAS_MANIFEST_REPO:-}"
    echo "ODH_PLATFORM_TYPE=${ODH_PLATFORM_TYPE}"
    if [[ -n "${maas_override:-}" ]]; then
      echo "MAAS_OVERRIDE=${maas_override}"
      echo "GET_ALL_MANIFESTS_ARG_MAAS=--maas=${maas_override}"
    else
      echo "MAAS_OVERRIDE="
      echo "GET_ALL_MANIFESTS_ARG_MAAS=(none — MAAS_MANIFEST_USE_UPSTREAM_PIN=1; upstream [\"maas\"] in get_all_manifests.sh applies)"
    fi
    if [[ -n "${aigateway_override:-}" ]]; then
      echo "AIGATEWAY_OVERRIDE=${aigateway_override}"
      echo "GET_ALL_MANIFESTS_ARG_AIGATEWAY=--aigateway=${aigateway_override}"
    else
      echo "AIGATEWAY_OVERRIDE="
      echo "GET_ALL_MANIFESTS_ARG_AIGATEWAY="
    fi
    if [[ -n "${dashboard_override:-}" ]]; then
      echo "DASHBOARD_OVERRIDE=${dashboard_override}"
      echo "GET_ALL_MANIFESTS_ARG_DASHBOARD=--dashboard=${dashboard_override}"
    else
      echo "DASHBOARD_OVERRIDE="
      echo "GET_ALL_MANIFESTS_ARG_DASHBOARD="
    fi
    echo "MAAS_CONTROLLER_IMAGE_EFFECTIVE=${MAAS_CONTROLLER_IMAGE_EFFECTIVE:-}"
    echo "MAAS_API_IMAGE_EFFECTIVE=${MAAS_API_IMAGE_EFFECTIVE:-}"
  } > "${MANIFEST_ARTIFACT_DIR}/maas-fetch-effective.txt"
  echo "Manifest validation artifacts: ${MANIFEST_ARTIFACT_DIR}/ (get_all_manifests.sh, maas-fetch-effective.txt)"
else
  echo "Skipping get-manifests"
fi

echo "Building and pushing operator image..."
make "${MAKE_ARGS[@]}" image

VERSION_RESOLVED="$(make "${MAKE_ARGS[@]}" -s print-VERSION)"
if [[ -n "${UNIFIED_IMAGE_TAG}" ]]; then
  olm_image_tag="${UNIFIED_IMAGE_TAG}"
  echo "UNIFIED_IMAGE_TAG=${UNIFIED_IMAGE_TAG} — operator, bundle, and catalog share this tag; Makefile VERSION/CSV is ${VERSION_RESOLVED} (derived from unified tag)."
else
  olm_image_tag="v${VERSION_RESOLVED}"
fi
if [[ -n "${BUNDLE_REPO:-}" ]]; then
  BUNDLE_IMG="${BUNDLE_REPO}:${olm_image_tag}"
else
  BUNDLE_IMG="${IMAGE_TAG_BASE}-bundle:${olm_image_tag}"
fi
if [[ -n "${CATALOG_REPO:-}" ]]; then
  CATALOG_IMG="${CATALOG_REPO}:${olm_image_tag}"
else
  CATALOG_IMG="${IMAGE_TAG_BASE}-catalog:${olm_image_tag}"
fi

echo "Building and pushing bundle image (${BUNDLE_IMG})..."
run_make_with_retry "${MAKE_ARGS[@]}" BUNDLE_IMG="${BUNDLE_IMG}" bundle-build bundle-push

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

OPENSHIFT_CATALOG_SNIPPET="$(build_openshift_catalog_snippet "${CATALOG_IMG}" "${OPERATOR_STARTING_CSV}" "${OPERATOR_CSV_PACKAGE}" "fast")"

{
  echo "OPERATOR_IMAGE=${OPERATOR_IMG}"
  echo "BUNDLE_IMAGE=${BUNDLE_IMG}"
  echo "CATALOG_IMAGE=${CATALOG_IMG}"
  echo "IMAGE_TAG_BASE=${IMAGE_TAG_BASE}"
  echo "BUNDLE_REPO=${BUNDLE_REPO:-}"
  echo "CATALOG_REPO=${CATALOG_REPO:-}"
  echo "MAAS_OVERRIDE=${maas_override:-}"
  echo "AIGATEWAY_OVERRIDE=${aigateway_override:-}"
  echo "DASHBOARD_OVERRIDE=${dashboard_override:-}"
  echo "OPERATOR_REPO_URL=${OPERATOR_REPO_URL:-}"
  echo "OPERATOR_GIT_REF=${OPERATOR_GIT_REF:-}"
  echo "AI_GATEWAY_REPO_URL=${AI_GATEWAY_REPO_URL:-}"
  echo "AI_GATEWAY_GIT_REF=${AI_GATEWAY_GIT_REF:-}"
  echo "AI_GATEWAY_IMAGE=${AI_GATEWAY_IMAGE:-}"
  echo "AI_GATEWAY_IMAGE_EFFECTIVE=${AI_GATEWAY_IMAGE_EFFECTIVE:-}"
  echo "MAAS_REPO_URL=${MAAS_REPO_URL:-${MAAS_MANIFEST_REPO_URL:-}}"
  echo "MAAS_GIT_REF=${MAAS_GIT_REF:-${MAAS_MANIFEST_REF:-}}"
  echo "MAAS_MANIFEST_REPO_URL=${MAAS_MANIFEST_REPO_URL:-}"
  echo "MAAS_MANIFEST_RESOLVED_REF=${MAAS_RESOLVED_REF:-}"
  echo "MAAS_CONTROLLER_IMAGE_EFFECTIVE=${MAAS_CONTROLLER_IMAGE_EFFECTIVE:-}"
  echo "MAAS_API_IMAGE_EFFECTIVE=${MAAS_API_IMAGE_EFFECTIVE:-}"
  echo "IMG_TAG=${IMG_TAG}"
  echo "UNIFIED_IMAGE_TAG=${UNIFIED_IMAGE_TAG:-}"
  echo "VERSION=${VERSION_RESOLVED}"
  echo "OPERATOR_STARTING_CSV=${OPERATOR_STARTING_CSV}"
  if [[ "${SKIP_GET_MANIFESTS}" != "1" ]]; then
    echo "MANIFEST_VALIDATION_DIR=${MANIFEST_ARTIFACT_DIR:-}"
  fi
  # Shell-quote so `source build-output.env` does not treat --flags as commands
  printf 'MAAS_DEPLOY_COMMAND=%q\n' "${MAAS_DEPLOY_COMMAND}"
  printf 'MAAS_DEPLOY_SNIPPET=%q\n' "${MAAS_DEPLOY_SNIPPET}"
  printf 'OPENSHIFT_CATALOG_SNIPPET=%q\n' "${OPENSHIFT_CATALOG_SNIPPET}"
} | tee "$BUILD_OUTPUT_ENV"

echo ""
echo "========== Build complete =========="
echo "Operator image: ${OPERATOR_IMG}"
echo "Bundle image:   ${BUNDLE_IMG}"
echo "Catalog image:  ${CATALOG_IMG}"
echo "===================================="
echo ""
echo "OpenShift custom catalog (save as odh-custom-catalog.yaml, then: oc apply -f odh-custom-catalog.yaml):"
echo "${OPENSHIFT_CATALOG_SNIPPET}"
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
