#!/usr/bin/env bash
# Remove ODH stack from cluster (operands, OLM subscription/CSV, custom catalog).
# Optionally remove local build clones and generated artifacts.
#
# Usage:
#   CONFIRM=remove-all ./scripts/cleanup-odh-stack.sh
#   CONFIRM=remove-all ./scripts/cleanup-odh-stack.sh --local
#
# Options:
#   --local     Also remove /tmp clones and repo build-output files
#   --keep-ns   Do not delete the opendatahub namespace (default: delete it)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEEP_NS=0
CLEAN_LOCAL=0
for arg in "$@"; do
  case "${arg}" in
    --local) CLEAN_LOCAL=1 ;;
    --keep-ns) KEEP_NS=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      exit 1
      ;;
  esac
done

if [[ "${CONFIRM:-}" != "remove-all" ]]; then
  echo "Refusing to run without CONFIRM=remove-all" >&2
  echo "Example: CONFIRM=remove-all $0 [--local]" >&2
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in to the cluster (run: oc login ...)" >&2
  exit 1
fi

echo "=== Cluster: ${CONFIRM} teardown ==="
echo "Context: $(oc config current-context 2>/dev/null || true)"
echo ""

patch_clear_finalizers() {
  local kind="$1" name="$2" ns="${3:-}"
  local jsonpath='metadata.finalizers'
  if [[ -n "${ns}" ]]; then
    oc patch "${kind}" "${name}" -n "${ns}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  else
    oc patch "${kind}" "${name}" --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  fi
}

delete_cr_if_exists() {
  local kind="$1" name="$2" ns="${3:-}"
  if [[ -n "${ns}" ]]; then
    oc get "${kind}" "${name}" -n "${ns}" &>/dev/null || return 0
    echo "Deleting ${kind}/${name} in ${ns}..."
    oc delete "${kind}" "${name}" -n "${ns}" --timeout=120s 2>/dev/null \
      || patch_clear_finalizers "${kind}" "${name}" "${ns}"
    oc delete "${kind}" "${name}" -n "${ns}" --ignore-not-found --timeout=60s 2>/dev/null || true
  else
    oc get "${kind}" "${name}" &>/dev/null || return 0
    echo "Deleting ${kind}/${name}..."
    oc delete "${kind}" "${name}" --timeout=120s 2>/dev/null \
      || patch_clear_finalizers "${kind}" "${name}"
    oc delete "${kind}" "${name}" --ignore-not-found --timeout=60s 2>/dev/null || true
  fi
}

echo "--- Removing ODH operands (opendatahub namespace) ---"
if oc get namespace opendatahub &>/dev/null; then
  for cr in \
    "dsc default-dsc" \
    "datasciencecluster default-dsc" \
    "aigateway default-aigateway" \
    "dscinitialization default-dsci" \
    "dscinitialization default-dsc-init" \
    "modelsasservice default-maas" \
    "modelsasservices default-maas"; do
    read -r kind name <<< "${cr}"
    delete_cr_if_exists "${kind}" "${name}" opendatahub
  done

  echo "Deleting remaining custom resources in opendatahub..."
  for api in \
    aigateways.aigateway.opendatahub.io \
    modelsasservices.components.platform.opendatahub.io \
    modelsasservice.maas.opendatahub.io; do
    oc delete "${api}" --all -n opendatahub --timeout=120s 2>/dev/null \
      || oc delete "${api}" --all -n opendatahub --ignore-not-found --wait=false 2>/dev/null || true
  done

  echo "Waiting for operand pods to terminate..."
  for i in $(seq 1 24); do
    count=$(oc get pods -n opendatahub --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "[$i] pods in opendatahub: ${count}"
    [[ "${count}" == "0" ]] && break
    sleep 5
  done
fi

echo "--- Removing OLM operator install ---"
if oc get subscription opendatahub-operator -n openshift-operators &>/dev/null; then
  echo "Deleting subscription opendatahub-operator..."
  oc delete subscription opendatahub-operator -n openshift-operators --timeout=120s 2>/dev/null || true
fi

echo "Deleting opendatahub-operator CSVs..."
oc get csv -n openshift-operators -o name 2>/dev/null \
  | grep -E 'opendatahub-operator|rhoai-operator|rhods-operator' \
  | xargs -r oc delete -n openshift-operators --timeout=120s 2>/dev/null || true

echo "Deleting related installplans..."
oc get installplan -n openshift-operators -o json 2>/dev/null \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    name = item['metadata']['name']
    refs = json.dumps(item)
    if 'opendatahub-operator' in refs or 'rhods-operator' in refs:
        print(name)
" 2>/dev/null | xargs -r -I{} oc delete installplan {} -n openshift-operators --ignore-not-found 2>/dev/null || true

if oc get catalogsource opendatahub-catalog -n openshift-marketplace &>/dev/null; then
  echo "Deleting catalogsource opendatahub-catalog..."
  oc delete catalogsource opendatahub-catalog -n openshift-marketplace --timeout=60s 2>/dev/null || true
fi

oc delete deployment opendatahub-operator-controller-manager -n openshift-operators --ignore-not-found 2>/dev/null || true

if [[ "${KEEP_NS}" == "0" ]] && oc get namespace opendatahub &>/dev/null; then
  echo "Deleting namespace opendatahub..."
  oc delete namespace opendatahub --timeout=180s 2>/dev/null \
    || patch_clear_finalizers namespace opendatahub
  oc delete namespace opendatahub --ignore-not-found --timeout=120s 2>/dev/null || true
fi

echo ""
echo "=== Cluster cleanup status ==="
oc get subscription,csv -n openshift-operators 2>/dev/null | grep -E 'opendatahub|rhods|rhoai' || echo "No ODH OLM resources in openshift-operators"
oc get catalogsource opendatahub-catalog -n openshift-marketplace 2>/dev/null || echo "No opendatahub-catalog"
oc get namespace opendatahub 2>/dev/null || echo "No opendatahub namespace"

if [[ "${CLEAN_LOCAL}" == "1" ]]; then
  echo ""
  echo "=== Local cleanup ==="
  rm -rf /tmp/opendatahub-operator /tmp/ai-gateway-operator /tmp/models-as-a-service
  rm -rf "${ROOT}/manifest-validation"
  rm -f "${ROOT}/build-output.env" "${ROOT}/ai-gateway-build-output.env"
  echo "Removed /tmp clones, manifest-validation, and build-output env files."
fi

echo "Done."
