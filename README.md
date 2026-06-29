# Build and deploy ODH stack (Quay)

This repository automates building and pushing the **Open Data Hub stack**:

1. **[AI Gateway operator](https://github.com/opendatahub-io/ai-gateway-operator)** — module operator (ODH → AI Gateway)
2. **[Open Data Hub operator](https://github.com/opendatahub-io/opendatahub-operator)** — operator, OLM bundle, and catalog (AI Gateway → MaaS manifests)

## What gets built

| Output | Image reference |
|--------|-----------------|
| AI Gateway operator | `$QUAY_AI_GATEWAY_REPO:$tag` |
| ODH operator | `$QUAY_REPO:$tag` |
| OLM bundle | `$QUAY_BUNDLE_REPO:$tag` or `$QUAY_REPO-bundle:$tag` |
| Catalog | `$QUAY_CATALOG_REPO:$tag` or `$QUAY_REPO-catalog:$tag` |

**`<tag>`** comes from **`QUAY_UNIFIED_IMAGE_TAG`** when set (`vX.Y.Z` or `X.Y.Z`, normalized to `vX.Y.Z`). Otherwise the operator and AI Gateway use **`latest`**; bundle and catalog use **`v$VERSION`** from the upstream Makefile.

The ODH build wires **MaaS** and **AI Gateway** manifests via [`get_all_manifests.sh`](https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh) overrides (`--maas=`, `--aigateway=`). When the stack script runs, the freshly built **AI Gateway image** is patched into the fetched manifests.

## GitHub Actions

Workflow: [`.github/workflows/build-odh-operator-catalog.yml`](.github/workflows/build-odh-operator-catalog.yml) — **Build ODH stack**.

### Required secrets

| Secret | Purpose |
|--------|---------|
| `QUAY_USERNAME` | Quay.io user or robot account (CI only; optional locally if `podman login quay.io` already done) |
| `QUAY_PASSWORD` | Quay.io password or robot token (CI only; optional locally with existing login) |

### Repository variables

| Variable | Purpose |
|----------|---------|
| `QUAY_REPO` | ODH operator image path **without** tag (default: `quay.io/maas/opendatahub-operator`) |
| `QUAY_AI_GATEWAY_REPO` | AI Gateway operator image path **without** tag (default: `quay.io/maas/ai-gateway-operator`) |
| `QUAY_UNIFIED_IMAGE_TAG` | One tag for **all** stack images (`vX.Y.Z` or `X.Y.Z`) |
| `QUAY_BUNDLE_REPO` | Optional OLM bundle path without tag |
| `QUAY_CATALOG_REPO` | Optional catalog path without tag |
| `OPERATOR_REPO_URL` / `OPERATOR_GIT_REF` | **opendatahub-operator** source (defaults: upstream, `main`) |
| `AI_GATEWAY_REPO_URL` / `AI_GATEWAY_GIT_REF` | **ai-gateway-operator** source (defaults: upstream, `main`) |
| `MAAS_REPO_URL` / `MAAS_GIT_REF` | **MaaS** manifests source (defaults: `maas-billing`, `main`) |
| `MAAS_CONTROLLER_IMAGE` / `MAAS_API_IMAGE` | Optional MaaS operand image overrides |

Workflow dispatch inputs mirror these (leave empty to use variables). Legacy `MAAS_MANIFEST_*` variables are still honored by the build script for advanced use.

### After a successful run

- **Job summary** lists AI Gateway, operator, bundle, and catalog URLs plus a MaaS `deploy.sh` snippet.
- **Job outputs:** `ai_gateway_image`, `operator_image`, `bundle_image`, `catalog_image`, `version`, `operator_starting_csv`, `maas_deploy_command`, `maas_deploy_snippet`.
- **Artifacts:** `build-output.env`, `ai-gateway-build-output.env`, `manifest-validation/`.

## Local build

### Full stack (recommended)

```bash
# Local: podman login quay.io  (or export QUAY_USERNAME / QUAY_PASSWORD)
# Defaults: quay.io/maas/opendatahub-operator, quay.io/maas/ai-gateway-operator
export UNIFIED_IMAGE_TAG=v3.4.0   # optional; same tag on all images

# Optional component sources (repo + ref only):
# export OPERATOR_REPO_URL=https://github.com/myorg/opendatahub-operator.git
# export OPERATOR_GIT_REF=feature-branch
# export AI_GATEWAY_REPO_URL=https://github.com/opendatahub-io/ai-gateway-operator.git
# export AI_GATEWAY_GIT_REF=main
# export MAAS_REPO_URL=https://github.com/opendatahub-io/maas-billing
# export MAAS_GIT_REF=main

./scripts/build-odh-stack.sh
```

### ODH operator only

```bash
# podman login quay.io  (default image: quay.io/maas/opendatahub-operator)
./scripts/build-and-push-odh-operator.sh
```

### AI Gateway operator only

```bash
# optional override: export AI_GATEWAY_IMAGE_REPO=quay.io/myorg/ai-gateway-operator
# podman login quay.io  (or QUAY_USERNAME / QUAY_PASSWORD)
./scripts/build-and-push-ai-gateway-operator.sh
```

### Container runtime

```bash
IMAGE_BUILDER=podman ./scripts/build-odh-stack.sh
# Docker alternative:
IMAGE_BUILDER=docker ./scripts/build-odh-stack.sh
```

If bundle build fails with `sum.golang.org` connection errors, retry once; persistent failures:

```bash
export GOSUMDB=off
./scripts/build-odh-stack.sh
```

## MaaS deploy

After building, deploy from a [maas-billing](https://github.com/opendatahub-io/maas-billing) clone using values from `build-output.env`:

```bash
OPERATOR_STARTING_CSV='<OPERATOR_STARTING_CSV>' ./scripts/deploy.sh \
  --operator-catalog '<CATALOG_IMAGE>' \
  --operator-image '<OPERATOR_IMAGE>' \
  --channel fast
```

See [Models-as-a-Service install](https://opendatahub-io.github.io/models-as-a-service/latest/install/maas-setup/).

### OpenShift custom catalog

After a build, `build-output.env` includes **`OPENSHIFT_CATALOG_SNIPPET`** — YAML for a `CatalogSource`, `OperatorGroup`, and `Subscription`. The ODH operator supports **AllNamespaces** only: install the Subscription in **`openshift-operators`** and use the existing **`global-operators`** OperatorGroup — do **not** create a second OperatorGroup in that namespace (OLM will not generate an InstallPlan). Create **`opendatahub`** separately for DSC/DSCI CRs.

```bash
source build-output.env
printf '%s\n' "${OPENSHIFT_CATALOG_SNIPPET}" > odh-custom-catalog.yaml
oc apply -f odh-custom-catalog.yaml
```

If the catalog or operator images are on a private registry, attach a pull secret to **`openshift-marketplace`** (and the operator namespace if required) before applying.

## Upstream documentation

- [opendatahub-operator](https://github.com/opendatahub-io/opendatahub-operator)
- [ai-gateway-operator](https://github.com/opendatahub-io/ai-gateway-operator)
