#!/usr/bin/env bash
# Fresh install of ODH stack from build-output.env (catalog, OLM, DSC/DSCI).
#
# Usage:
#   ./scripts/install-odh-stack.sh
#   CLEAN=1 ./scripts/install-odh-stack.sh   # cleanup cluster first
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

: "${CATALOG_IMAGE:?}"
: "${OPERATOR_STARTING_CSV:?}"

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in (run: oc login ...)" >&2
  exit 1
fi

if [[ "${CLEAN:-0}" == "1" ]]; then
  CONFIRM=remove-all "${SCRIPT_DIR}/cleanup-odh-stack.sh"
fi

echo "=== Installing ODH stack ${UNIFIED_IMAGE_TAG:-${OPERATOR_STARTING_CSV}} ==="

if ! oc get catalogsource opendatahub-catalog -n openshift-marketplace &>/dev/null; then
  echo "--- Creating catalogsource ---"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: opendatahub-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${CATALOG_IMAGE}
  displayName: Open Data Hub (custom)
  publisher: Custom
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
else
  echo "--- Updating catalogsource ---"
  oc patch catalogsource opendatahub-catalog -n openshift-marketplace --type merge \
    -p "{\"spec\":{\"image\":\"${CATALOG_IMAGE}\"}}"
fi

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

echo "--- Installing subscription ---"
if oc get subscription opendatahub-operator -n openshift-operators &>/dev/null; then
  oc patch subscription opendatahub-operator -n openshift-operators --type merge \
    -p "{\"spec\":{\"startingCSV\":\"${OPERATOR_STARTING_CSV}\",\"installPlanApproval\":\"Automatic\",\"channel\":\"fast\",\"source\":\"opendatahub-catalog\",\"sourceNamespace\":\"openshift-marketplace\"}}"
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

oc scale deployment/opendatahub-operator-controller-manager -n openshift-operators --replicas=1 2>/dev/null || true
oc rollout status deployment/opendatahub-operator-controller-manager -n openshift-operators --timeout=180s 2>/dev/null || true

echo "--- Applying DSCInitialization and DataScienceCluster ---"
oc create namespace opendatahub --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<'EOF'
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: opendatahub
  monitoring:
    managementState: Managed
    metrics: {}
    namespace: opendatahub
  trustedCABundle:
    customCABundle: ""
    managementState: Managed
EOF

for i in $(seq 1 36); do
  ready=$(oc get dscinitialization default-dsci -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  echo "[$i] dsci Ready=${ready}"
  [[ "${ready}" == "True" ]] && break
  sleep 5
done

oc apply -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    aigateway:
      managementState: Managed
      modelsAsService:
        managementState: Managed
    aipipelines:
      argoWorkflowsControllers:
        managementState: Removed
      managementState: Removed
    dashboard:
      managementState: Managed
    feastoperator:
      managementState: Removed
    kserve:
      managementState: Removed
      modelCache:
        managementState: Removed
      modelsAsService:
        managementState: Removed
      nim:
        airGapped: false
        managementState: Managed
      rawDeploymentServiceConfig: Headed
      wva:
        managementState: Removed
    kueue:
      autoCreateQueues: false
      defaultClusterQueueName: default
      defaultLocalQueueName: default
      managementState: Removed
    llamastackoperator:
      managementState: Removed
    mlflowoperator:
      managementState: Removed
    modelregistry:
      managementState: Removed
      registriesNamespace: odh-model-registries
    ogx:
      managementState: Removed
    ray:
      managementState: Removed
    sparkoperator:
      managementState: Removed
    trainer:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      eval:
        lmeval:
          permitCodeExecution: deny
          permitOnline: deny
      managementState: Removed
      mcpGuardrailsMode: false
    workbenches:
      managementState: Removed
      workbenchNamespace: opendatahub
EOF

echo "--- Waiting for AI Gateway ---"
for i in $(seq 1 60); do
  gw_ready=$(oc get aigateway default-aigateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  gw_msg=$(oc get aigateway default-aigateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || true)
  dsc_ready=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  echo "[$i] dsc=${dsc_ready} aigateway=${gw_ready} ${gw_msg}"
  [[ "${gw_ready}" == "True" && "${dsc_ready}" == "True" ]] && break
  sleep 10
done

echo ""
echo "=== Status ==="
oc get csv,subscription -n openshift-operators 2>/dev/null | grep opendatahub || true
oc get deployment opendatahub-operator-controller-manager -n openshift-operators \
  -o jsonpath='operator={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
oc get deployment ai-gateway-operator -n opendatahub \
  -o jsonpath='ai-gateway={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
oc get pods -n opendatahub -l app.kubernetes.io/name=ai-gateway-operator 2>/dev/null || true
oc get aigateway default-aigateway \
  -o jsonpath='AIGateway Ready={.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}' 2>/dev/null || true
echo "Done."
