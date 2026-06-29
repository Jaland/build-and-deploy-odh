#!/usr/bin/env bash
# Shared helpers for component repo/ref overrides (org:repo:ref:path for get_all_manifests.sh).
# Source from build scripts; do not execute directly.

parse_github_repo_url() {
  local url="${1:-}"
  [[ -z "${url}" ]] && return 1
  if [[ "${url}" =~ ^https?://github\.com/([^/]+)/([^/[:space:]]+) ]]; then
    GITHUB_ORG="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    repo="${repo%.git}"
    GITHUB_REPO="${repo}"
    return 0
  fi
  echo "ERROR: URL must be a GitHub HTTPS URL, e.g. https://github.com/opendatahub-io/ai-gateway-operator — got: ${url}" >&2
  return 1
}

build_component_override() {
  local org="$1" repo="$2" ref="$3" path="$4"
  echo "${org}:${repo}:${ref}:${path}"
}

resolve_branch_head_sha() {
  local org="$1" repo="$2" branch="$3"
  git ls-remote "https://github.com/${org}/${repo}.git" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}'
}

resolve_unified_image_tag() {
  UNIFIED_IMAGE_TAG="${UNIFIED_IMAGE_TAG:-}"
  IMG_TAG="${IMG_TAG:-latest}"
  if [[ -z "${UNIFIED_IMAGE_TAG}" ]]; then
    return 0
  fi
  local raw="${UNIFIED_IMAGE_TAG}"
  if [[ "${raw}" =~ ^v[0-9] ]]; then
    UNIFIED_IMAGE_TAG="${raw}"
    VERSION="${raw#v}"
  elif [[ "${raw}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then
    UNIFIED_IMAGE_TAG="v${raw}"
    VERSION="${raw}"
  else
    echo "ERROR: UNIFIED_IMAGE_TAG must be semver vX.Y.Z or X.Y.Z (e.g. v3.4.0 or 3.4.0); got: ${raw}" >&2
    return 1
  fi
  IMG_TAG="${UNIFIED_IMAGE_TAG}"
  export UNIFIED_IMAGE_TAG IMG_TAG VERSION
}

clone_git_repo() {
  local repo_url="$1" git_ref="$2" clone_dir="$3"
  if [[ ! -d "${clone_dir}/.git" ]]; then
    rm -rf "${clone_dir}"
    git clone --depth 1 --branch "${git_ref}" "${repo_url}" "${clone_dir}" 2>/dev/null || {
      git clone "${repo_url}" "${clone_dir}"
      git -C "${clone_dir}" fetch --depth 1 origin "${git_ref}"
      git -C "${clone_dir}" checkout "${git_ref}"
    }
  else
    echo "Using existing clone at ${clone_dir}"
    git -C "${clone_dir}" fetch origin
    git -C "${clone_dir}" checkout "${git_ref}"
    git -C "${clone_dir}" pull --ff-only 2>/dev/null || true
  fi
}

# Use go.mod toolchain when the installed Go is older (e.g. GOTOOLCHAIN=local on Fedora).
ensure_go_toolchain() {
  if [[ "${GOTOOLCHAIN:-local}" == "local" ]]; then
    export GOTOOLCHAIN=auto
  fi
}

registry_login_user() {
  local builder="$1" host="$2"
  "${builder}" login --get-login "${host}" 2>/dev/null
}

registry_has_login() {
  local user
  user="$(registry_login_user "$1" "$2")"
  [[ -n "${user}" ]]
}

# Log in with QUAY_USERNAME/QUAY_PASSWORD when set; otherwise use existing podman/docker auth.
ensure_registry_login() {
  local builder="$1"
  local username="${2:-}"
  local password="${3:-}"
  shift 3
  local host
  while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    if [[ -n "${username}" && -n "${password}" ]]; then
      echo "Logging in to ${host}..."
      echo "${password}" | "${builder}" login "${host}" -u "${username}" --password-stdin
    elif registry_has_login "${builder}" "${host}"; then
      echo "Using existing ${builder} login for ${host} ($(registry_login_user "${builder}" "${host}"))"
    else
      echo "ERROR: Not logged in to ${host}." >&2
      echo "Run: ${builder} login ${host}" >&2
      echo "Or set QUAY_USERNAME and QUAY_PASSWORD." >&2
      exit 1
    fi
  done < <(for ref in "$@"; do [[ -z "${ref}" ]] && continue; echo "${ref%%/*}"; done | sort -u)
}

login_registry_hosts() {
  ensure_registry_login "$@"
}

# Bundle image build runs `go install` inside Dockerfiles/bundle.Dockerfile; inject GOPROXY/GOSUMDB
# and allow layer cache on retry when sum.golang.org is flaky. Set GOSUMDB=off to skip checksum lookup.
prepare_operator_go_build() {
  local op_root="${1:?}"
  ensure_go_toolchain
  export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
  export GOSUMDB="${GOSUMDB:-sum.golang.org}"

  local bundle_df="${op_root}/Dockerfiles/bundle.Dockerfile"
  if [[ -f "${bundle_df}" ]] && ! grep -q 'build-and-deploy-odh GOPROXY patch' "${bundle_df}"; then
    echo "Patching ${bundle_df} for Go module fetch (GOPROXY=${GOPROXY}, GOSUMDB=${GOSUMDB})..."
    _PATCH_GOPROXY="${GOPROXY}" _PATCH_GOSUMDB="${GOSUMDB}" _PATCH_GOT="${GOTOOLCHAIN}" perl -i -pe '
      if (/^WORKDIR \/workspace/ && !$done++) {
        $_ .= "# build-and-deploy-odh GOPROXY patch\n";
        $_ .= "ENV GOPROXY=$ENV{_PATCH_GOPROXY}\n";
        $_ .= "ENV GOSUMDB=$ENV{_PATCH_GOSUMDB}\n";
        $_ .= "ENV GOTOOLCHAIN=$ENV{_PATCH_GOT}\n";
      }
    ' "${bundle_df}"
  fi

  local mk="${op_root}/Makefile"
  if [[ -f "${mk}" && "${BUNDLE_BUILD_NO_CACHE:-}" != "1" ]] \
    && grep -q 'build --no-cache -f Dockerfiles/\$(BUNDLE_DOCKERFILE_FILENAME)' "${mk}" \
    && ! grep -q 'build-and-deploy-odh bundle-build cache patch' "${mk}"; then
    echo "Patching ${mk}: drop --no-cache from bundle-build (set BUNDLE_BUILD_NO_CACHE=1 for upstream behavior)..."
    perl -i -pe '
      if (/^\t.*\$\(IMAGE_BUILDER\) build --no-cache -f Dockerfiles\/\$\(BUNDLE_DOCKERFILE_FILENAME\)/) {
        s/ --no-cache//;
        $_ = "# build-and-deploy-odh bundle-build cache patch\n$_" unless $marker++;
      }
    ' "${mk}"
  fi
}

run_make_with_retry() {
  local attempts="${MAKE_RETRY_ATTEMPTS:-3}"
  local delay="${MAKE_RETRY_DELAY_SEC:-15}"
  local n=1
  while [[ "${n}" -le "${attempts}" ]]; do
    if make "$@"; then
      return 0
    fi
    if [[ "${n}" -eq "${attempts}" ]]; then
      echo "ERROR: make failed after ${attempts} attempt(s): make $*" >&2
      if [[ "${GOSUMDB}" == "sum.golang.org" ]]; then
        echo "Hint: transient sum.golang.org errors — retry, or set GOSUMDB=off and re-run." >&2
      fi
      return 1
    fi
    echo "make failed (attempt ${n}/${attempts}); retrying in ${delay}s..."
    sleep "${delay}"
    n=$((n + 1))
  done
}

# Emit YAML + oc hints for installing the built FBC catalog on OpenShift.
build_openshift_catalog_snippet() {
  local catalog_img="$1"
  local starting_csv="$2"
  local operator_package="${3:-opendatahub-operator}"
  local channel="${4:-fast}"
  local catalog_name="${OPENSHIFT_CATALOG_SOURCE_NAME:-opendatahub-catalog}"
  # ODH CSV supports AllNamespaces only. openshift-operators already has global-operators — do not add another OG.
  local operator_ns="${OPENSHIFT_OPERATOR_NAMESPACE:-openshift-operators}"
  local dsc_ns="${OPENSHIFT_DSC_NAMESPACE:-opendatahub}"

  cat <<EOF
# OpenShift: add your custom OLM catalog, then install the operator from it.
# Catalog image: ${catalog_img}
# Package: ${operator_package}  Channel: ${channel}  startingCSV: ${starting_csv}
#
# The ODH operator CSV supports AllNamespaces only. Install the Subscription in ${operator_ns}
# and reuse the existing global-operators OperatorGroup — do NOT create a second OperatorGroup there.
# Create ${dsc_ns} later for DSCInitialization / DataScienceCluster CRs.
#
# If images are on a private registry, attach a pull secret to openshift-marketplace first, e.g.:
#   oc -n openshift-marketplace create secret docker-registry custom-catalog-pull \\
#     --docker-server=quay.io --docker-username=... --docker-password=...
#   oc -n openshift-marketplace secrets link default custom-catalog-pull --for=pull
#
# Apply (save as odh-custom-catalog.yaml):
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${catalog_img}
  displayName: Open Data Hub (custom)
  publisher: Custom
  updateStrategy:
    registryPoll:
      interval: 10m
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${operator_package}
  namespace: ${operator_ns}
spec:
  channel: ${channel}
  name: ${operator_package}
  source: ${catalog_name}
  sourceNamespace: openshift-marketplace
  startingCSV: ${starting_csv}
  installPlanApproval: Automatic
#
# oc apply -f odh-custom-catalog.yaml
# oc get catalogsource ${catalog_name} -n openshift-marketplace
# oc get packagemanifest ${operator_package} -n openshift-marketplace
# oc get subscription,csv -n ${operator_ns}
# oc create namespace ${dsc_ns}   # then apply DSCInitialization / DataScienceCluster here
#
# Console: add CatalogSource, then install ${operator_package} in ${operator_ns}, mode "All namespaces".
EOF
}
