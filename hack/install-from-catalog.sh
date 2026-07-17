#!/usr/bin/env bash
# Install or upgrade the ODH stack on OpenShift from a catalog image tag.
#
# Derives operator CSV, operator image, and AI Gateway image from the catalog URL
# (same unified tag as build-odh-stack.sh / UNIFIED_IMAGE_TAG).
#
# Usage:
#   ./hack/install-from-catalog.sh quay.io/maas/opendatahub-operator-catalog:v2.0.79-maas
#
# Optional env:
#   OPERATOR_IMAGE_REPO     default: quay.io/maas/opendatahub-operator
#   AI_GATEWAY_IMAGE_REPO   default: quay.io/maas/ai-gateway-operator
#   OPERATOR_PACKAGE        default: opendatahub-operator
#   OPERATOR_CHANNEL        default: fast
#   CATALOG_SOURCE_NAME     default: opendatahub-catalog
#   OPERATOR_NAMESPACE      default: openshift-operators
#   DSC_NAMESPACE           default: opendatahub
#   FORCE_REINSTALL         default: 1 — delete subscription + CSV before reinstall
#                           (OLM patch-only upgrades often stay on an old installedCSV)
#   SKIP_BOUNCE             If 1, skip AI Gateway restart and DSC annotation
#
set -euo pipefail

usage() {
  cat <<EOF
Usage:
  $0 <catalog-image>

Install or upgrade ODH from a catalog image (unified tag).

Example:
  $0 quay.io/maas/opendatahub-operator-catalog:v2.0.79-maas

Optional env: OPERATOR_IMAGE_REPO, AI_GATEWAY_IMAGE_REPO, FORCE_REINSTALL (default 1),
SKIP_BOUNCE, CATALOG_SOURCE_NAME, OPERATOR_NAMESPACE, DSC_NAMESPACE
EOF
}

CATALOG_IMAGE="${1:-}"
if [[ -z "${CATALOG_IMAGE}" || "${CATALOG_IMAGE}" == "-h" || "${CATALOG_IMAGE}" == "--help" ]]; then
  usage
  exit 0
fi

OPERATOR_IMAGE_REPO="${OPERATOR_IMAGE_REPO:-quay.io/maas/opendatahub-operator}"
AI_GATEWAY_IMAGE_REPO="${AI_GATEWAY_IMAGE_REPO:-quay.io/maas/ai-gateway-operator}"
OPERATOR_PACKAGE="${OPERATOR_PACKAGE:-opendatahub-operator}"
OPERATOR_CHANNEL="${OPERATOR_CHANNEL:-fast}"
CATALOG_SOURCE_NAME="${CATALOG_SOURCE_NAME:-opendatahub-catalog}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-openshift-operators}"
DSC_NAMESPACE="${DSC_NAMESPACE:-opendatahub}"
FORCE_REINSTALL="${FORCE_REINSTALL:-1}"
SKIP_BOUNCE="${SKIP_BOUNCE:-0}"

if [[ "${CATALOG_IMAGE}" != *:* ]]; then
  echo "ERROR: catalog image must include a tag, e.g. quay.io/maas/opendatahub-operator-catalog:v2.0.79-maas" >&2
  exit 1
fi

IMG_TAG="${CATALOG_IMAGE##*:}"
OPERATOR_STARTING_CSV="${OPERATOR_PACKAGE}.${IMG_TAG}"
OPERATOR_IMAGE="${OPERATOR_IMAGE_REPO}:${IMG_TAG}"
AI_GATEWAY_IMAGE="${AI_GATEWAY_IMAGE_REPO}:${IMG_TAG}"

if ! oc whoami &>/dev/null; then
  echo "ERROR: not logged in to the cluster (run: oc login ...)" >&2
  exit 1
fi

echo "=== Install ODH from catalog ==="
echo "Catalog:   ${CATALOG_IMAGE}"
echo "CSV:       ${OPERATOR_STARTING_CSV}"
echo "Operator:  ${OPERATOR_IMAGE}"
echo "AI Gateway:${AI_GATEWAY_IMAGE}"
echo ""

if [[ "${FORCE_REINSTALL}" == "1" ]]; then
  echo "--- Removing existing OLM install (force) ---"
  oc delete subscription "${OPERATOR_PACKAGE}" -n "${OPERATOR_NAMESPACE}" --ignore-not-found --wait=true
  while IFS= read -r csv; do
    [[ -z "${csv}" ]] && continue
    echo "Deleting ${csv}"
    oc delete "${csv}" -n "${OPERATOR_NAMESPACE}" --wait=true
  done < <(oc get csv -n "${OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep "${OPERATOR_PACKAGE}" || true)
fi

echo "--- CatalogSource ---"
if oc get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace &>/dev/null; then
  oc patch catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace --type merge \
    -p "{\"spec\":{\"image\":\"${CATALOG_IMAGE}\"}}"
else
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
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
fi

oc delete pod -n openshift-marketplace -l "olm.catalogSource=${CATALOG_SOURCE_NAME}" --wait=false 2>/dev/null || true

echo "--- Waiting for catalog + packagemanifest ---"
for i in $(seq 1 40); do
  status=$(oc get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  csv=$(oc get packagemanifest "${OPERATOR_PACKAGE}" \
    -o jsonpath="{.status.channels[?(@.name==\"${OPERATOR_CHANNEL}\")].currentCSV}" 2>/dev/null || true)
  echo "[$i] catalog=${status} packagemanifest=${csv}"
  [[ "${status}" == "READY" && "${csv}" == "${OPERATOR_STARTING_CSV}" ]] && break
  sleep 5
done

echo "--- Subscription ---"
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_PACKAGE}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: ${OPERATOR_CHANNEL}
  name: ${OPERATOR_PACKAGE}
  source: ${CATALOG_SOURCE_NAME}
  sourceNamespace: openshift-marketplace
  startingCSV: ${OPERATOR_STARTING_CSV}
  installPlanApproval: Automatic
EOF

echo "--- Waiting for CSV ---"
for i in $(seq 1 60); do
  phase=$(oc get csv "${OPERATOR_STARTING_CSV}" -n "${OPERATOR_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)
  echo "[$i] csv=${phase}"
  [[ "${phase}" == "Succeeded" ]] && break
  sleep 5
done

oc scale deployment/opendatahub-operator-controller-manager -n "${OPERATOR_NAMESPACE}" --replicas=1 2>/dev/null || true
oc rollout status deployment/opendatahub-operator-controller-manager -n "${OPERATOR_NAMESPACE}" --timeout=180s 2>/dev/null || true

echo "--- DataScienceCluster namespace + CRs ---"
oc create namespace "${DSC_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

if ! oc get dscinitialization default-dsci &>/dev/null; then
  oc apply -f - <<EOF
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: ${DSC_NAMESPACE}
  monitoring:
    managementState: Managed
    metrics: {}
    namespace: ${DSC_NAMESPACE}
  trustedCABundle:
    customCABundle: ""
    managementState: Managed
EOF
fi

if ! oc get datasciencecluster default-dsc &>/dev/null; then
  oc apply -f - <<EOF
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
      workbenchNamespace: ${DSC_NAMESPACE}
EOF
fi

if [[ "${SKIP_BOUNCE}" != "1" ]]; then
  echo "--- Bouncing AI Gateway + DSC ---"
  sleep 10
  if oc get deployment ai-gateway-operator -n "${DSC_NAMESPACE}" &>/dev/null; then
    oc rollout restart deployment/ai-gateway-operator -n "${DSC_NAMESPACE}"
    oc rollout status deployment/ai-gateway-operator -n "${DSC_NAMESPACE}" --timeout=300s || true
  fi
  if oc get datasciencecluster default-dsc &>/dev/null; then
    oc annotate datasciencecluster default-dsc \
      platform.opendatahub.io/redeploy="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
  fi
fi

echo ""
echo "=== Status ==="
oc get csv,subscription -n "${OPERATOR_NAMESPACE}" 2>/dev/null | grep "${OPERATOR_PACKAGE}" || true
oc get deployment opendatahub-operator-controller-manager -n "${OPERATOR_NAMESPACE}" \
  -o jsonpath='operator={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
oc get deployment ai-gateway-operator -n "${DSC_NAMESPACE}" \
  -o jsonpath='ai-gateway={.spec.template.spec.containers[0].image}{"\n"}' 2>/dev/null || true
oc get pods -n "${DSC_NAMESPACE}" -l app.kubernetes.io/name=ai-gateway-operator 2>/dev/null || true
if oc get aigateway default-aigateway &>/dev/null; then
  oc get aigateway default-aigateway \
    -o jsonpath='AIGateway Ready={.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].message}{"\n"}' 2>/dev/null || true
fi
echo "Done."
