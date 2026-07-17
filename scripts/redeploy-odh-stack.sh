#!/usr/bin/env bash
# Redeploy ODH stack to the cluster from build-output.env (OLM + AI Gateway bounce).
# Requires: oc logged in, build-output.env from a successful build-odh-stack.sh run.
#
# Usage:
#   source build-output.env   # or let this script load it
#   ./scripts/redeploy-odh-stack.sh
#
# Optional env:
#   BUILD_OUTPUT_ENV   Path to build-output.env (default: ../build-output.env)
#   SKIP_OLM_REINSTALL  If 1, skip subscription/catalog upgrade (bounce workloads only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_OUTPUT_ENV="${BUILD_OUTPUT_ENV:-${ROOT}/build-output.env}"

if [[ ! -f "${BUILD_OUTPUT_ENV}" ]]; then
  echo "ERROR: missing ${BUILD_OUTPUT_ENV} — run ./scripts/build-odh-stack.sh first" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${BUILD_OUTPUT_ENV}"

: "${CATALOG_IMAGE:?CATALOG_IMAGE not set in ${BUILD_OUTPUT_ENV}}"
: "${OPERATOR_STARTING_CSV:?OPERATOR_STARTING_CSV not set in ${BUILD_OUTPUT_ENV}}"
: "${OPERATOR_IMAGE:?OPERATOR_IMAGE not set in ${BUILD_OUTPUT_ENV}}"
: "${AI_GATEWAY_IMAGE_EFFECTIVE:=${AI_GATEWAY_IMAGE:-}}"

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in to the cluster (run: oc login ...)" >&2
  exit 1
fi

echo "=== Redeploy ODH stack ==="
echo "Catalog:  ${CATALOG_IMAGE}"
echo "CSV:      ${OPERATOR_STARTING_CSV}"
echo "Operator: ${OPERATOR_IMAGE}"
echo "AI GW:    ${AI_GATEWAY_IMAGE_EFFECTIVE:-<from params.env>}"
echo ""

if [[ "${SKIP_OLM_REINSTALL:-0}" != "1" ]]; then
  echo "--- Upgrading OLM catalog and operator ---"
  oc patch catalogsource opendatahub-catalog -n openshift-marketplace --type merge \
    -p "{\"spec\":{\"image\":\"${CATALOG_IMAGE}\"}}"
  oc delete pod -n openshift-marketplace -l olm.catalogSource=opendatahub-catalog --wait=false 2>/dev/null || true

  for i in $(seq 1 36); do
    status=$(oc get catalogsource opendatahub-catalog -n openshift-marketplace \
      -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    csv=$(oc get packagemanifest opendatahub-operator \
      -o jsonpath='{.status.channels[?(@.name=="fast")].currentCSV}' 2>/dev/null || true)
    echo "[$i] catalog=${status} packagemanifest=${csv}"
    [[ "${status}" == "READY" && "${csv}" == "${OPERATOR_STARTING_CSV}" ]] && break
    sleep 5
  done

  if oc get subscription opendatahub-operator -n openshift-operators &>/dev/null; then
    oc patch subscription opendatahub-operator -n openshift-operators --type merge \
      -p "{\"spec\":{\"startingCSV\":\"${OPERATOR_STARTING_CSV}\",\"installPlanApproval\":\"Automatic\"}}"
  else
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opendatahub-operator
  namespace: openshift-operators
spec:
  channel: fast
  name: opendatahub-operator
  source: opendatahub-catalog
  sourceNamespace: openshift-marketplace
  startingCSV: ${OPERATOR_STARTING_CSV}
  installPlanApproval: Automatic
EOF
  fi

  for i in $(seq 1 60); do
    phase=$(oc get csv "${OPERATOR_STARTING_CSV}" -n openshift-operators \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "[$i] csv=${phase}"
    [[ "${phase}" == "Succeeded" ]] && break
    sleep 5
  done

  oc scale deployment/opendatahub-operator-controller-manager -n openshift-operators --replicas=3 2>/dev/null \
    || oc scale deployment/opendatahub-operator-controller-manager -n openshift-operators --replicas=1 2>/dev/null || true
fi

echo "--- Bouncing AI Gateway and reconciling DSC ---"
if oc get deployment ai-gateway-operator -n opendatahub &>/dev/null; then
  oc rollout restart deployment/ai-gateway-operator -n opendatahub
  oc delete pod -n opendatahub -l app.kubernetes.io/name=ai-gateway-operator --wait=false 2>/dev/null || true
  oc rollout status deployment/ai-gateway-operator -n opendatahub --timeout=180s || true
fi

if oc get dsc default-dsc -n opendatahub &>/dev/null; then
  oc annotate dsc default-dsc -n opendatahub \
    platform.opendatahub.io/redeploy="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
elif oc get datasciencecluster default-dsc -n opendatahub &>/dev/null; then
  oc annotate datasciencecluster default-dsc -n opendatahub \
    platform.opendatahub.io/redeploy="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
fi

echo ""
echo "=== Status ==="
oc get csv,subscription -n openshift-operators 2>/dev/null | grep opendatahub || true
oc get deployment opendatahub-operator-controller-manager -n openshift-operators \
  -o jsonpath='operator={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
oc get pods -n opendatahub -l app.kubernetes.io/name=ai-gateway-operator 2>/dev/null || true
if oc get aigateway default-aigateway &>/dev/null; then
  oc get aigateway default-aigateway \
    -o jsonpath='AIGateway Ready={.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}' 2>/dev/null || true
fi
echo "Done."
