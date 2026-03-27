# Build and deploy ODH operator (Quay)

This repository automates building and pushing the [Open Data Hub operator](https://github.com/opendatahub-io/opendatahub-operator) container image, its OLM **bundle** image, and the **File-Based Catalog** (FBC) **catalog** image to Quay.io. It mirrors the upstream `Makefile` flow (`get-manifests`, `image`, `bundle-build`, `catalog-build`).

## What gets built

The script always builds and pushes the **operator** image, the OLM **bundle** image, and the **catalog** image. You can use one Quay repository base for operator + bundle and a **separate** repository for the catalog index (same credentials; the script logs in to each registry host it needs).

| Output | Image reference |
|--------|-----------------|
| Operator | `$IMAGE_TAG_BASE:$IMG_TAG` |
| Bundle | If `BUNDLE_REPO` is set: `$BUNDLE_REPO:v$VERSION`. Otherwise: `$IMAGE_TAG_BASE-bundle:v$VERSION` |
| Catalog | If `CATALOG_REPO` is set: `$CATALOG_REPO:v$VERSION`. Otherwise: `$IMAGE_TAG_BASE-catalog:v$VERSION` |

**Two different “versions”:**

- **`IMG_TAG`** (from `QUAY_TAG` or `img_tag`) is only the **operator** container tag: `quay.io/org/opendatahub-operator:mytag`.
- **`VERSION`** is the **OLM** bundle/catalog version used in image tags like `…-bundle:v3.3.0` and `…:v3.3.0`. It defaults to whatever the [upstream Makefile](https://github.com/opendatahub-io/opendatahub-operator/blob/main/Makefile) sets (often `3.3.0`) unless you set **`QUAY_OLM_VERSION`** (repository variable or secret) or the workflow **`version`** input. It does **not** follow `QUAY_TAG` automatically.

## GitHub Actions

Workflow: [`.github/workflows/build-odh-operator-catalog.yml`](.github/workflows/build-odh-operator-catalog.yml).

### Triggers

- **Push to `main`** — uses repository **variables** (and **secrets** for Quay credentials).
- **Workflow dispatch** — optional inputs override variables/secrets for that run.

### Repository variables (recommended for image paths and tags)

Configure under **Settings → Secrets and variables → Actions → Variables**. These values are **not** redacted in workflow logs. The workflow reads **`vars.NAME` first**, then falls back to **`secrets.NAME`** if you still store the same name as a secret.

| Variable | Purpose |
|----------|---------|
| `QUAY_REPO` | Operator image path **without** tag (e.g. `quay.io/myorg/opendatahub-operator`) |
| `QUAY_TAG` | Tag for the **operator** image only. If unset, the script defaults to `latest`. |
| `QUAY_OLM_VERSION` | Optional. OLM bundle/catalog version without a leading `v` (e.g. `3.4.0`). If unset, the upstream Makefile default applies (often `3.3.0`). |
| `QUAY_BUNDLE_REPO` | Optional. Separate **OLM bundle** image path **without** tag. If unset, bundle is `${QUAY_REPO}-bundle:v$VERSION`. |
| `QUAY_CATALOG_REPO` | Optional. Separate **catalog** index path **without** tag. If unset, catalog is `${QUAY_REPO}-catalog:v$VERSION`. |
| `MAAS_MANIFEST_*` | Optional MaaS overrides; same names as in the workflow file (`MAAS_MANIFEST_REF`, `MAAS_MANIFEST_PIN_LATEST`, etc.). |

### Required repository secrets

| Secret | Purpose |
|--------|---------|
| `QUAY_USERNAME` | Quay.io user or robot account name |
| `QUAY_PASSWORD` | Quay.io password or robot token |

### Optional secrets

| Secret | When |
|--------|------|
| `KUBECONFIG` | Raw kubeconfig, only for **workflow dispatch** with **Deploy bundle** enabled |
| Same names as variables | Fallback only if you prefer not to use repository variables; values are **masked** in logs. |

### Manual run inputs (workflow dispatch)

Leave any field empty to keep using the matching **variable** or **secret**.

| Input | Meaning |
|-------|---------|
| `image_tag_base` | Overrides `QUAY_REPO` for that run |
| `img_tag` | Overrides `QUAY_TAG` for that run |
| `bundle_repo` | Overrides `QUAY_BUNDLE_REPO` for that run |
| `catalog_repo` | Overrides `QUAY_CATALOG_REPO` for that run |
| `version` | OLM `VERSION` (empty = variable or secret `QUAY_OLM_VERSION`, else Makefile default) |
| `git_ref` | Upstream branch, tag, or commit (default `main`) |
| `deploy_bundle` | After push, run `operator-sdk run bundle` (needs `KUBECONFIG`) |
| `maas_manifest_ref` | Overrides `MAAS_MANIFEST_REF` for that run |
| `maas_manifest_pin_latest` | Pin `main` to the current commit (`main@sha`) |
| `maas_manifest_repo` / `maas_manifest_org` / `maas_manifest_source_path` | Override the matching variable or secret for that run |
| `maas_manifest_write_file` | Same as variable or secret `MAAS_MANIFEST_WRITE_FILE` |

### Optional MaaS (Models-as-a-Service) manifest source

The operator pulls **maas** manifests from GitHub (by default [maas-billing](https://github.com/opendatahub-io/maas-billing) under `deployment/`).

- **If you do nothing:** `get_all_manifests.sh` in the operator repo uses a **fixed pin** in its map (often `main@<commit>`). That is **not** automatically “latest `main`” on every build.
- **To follow `main` at each run:** set **`MAAS_MANIFEST_REF=main`**. The script passes `--maas=…:main:…` so the upstream fetch uses the **current tip of `main`** when the job runs (no permanent edit to `get_all_manifests.sh` unless **`MAAS_MANIFEST_WRITE_FILE=1`**).
- **To pin a commit explicitly:** set **`MAAS_MANIFEST_PIN_LATEST=1`** with **`MAAS_MANIFEST_REF=main`** (resolves to `main@<sha>` via `git ls-remote` at the start of the build), or pass a ref like **`main@abcdef…`** yourself.

After a successful fetch with a MaaS override, the build script **checks** that `opt/manifests/maas` exists and contains at least one file, and writes **`MAAS_MANIFEST_RESOLVED_REF`** to `build-output.env`.

To use a different repository name (for example another fork), set **`MAAS_MANIFEST_REPO`**. **`ODH_PLATFORM_TYPE=rhoai`** is supported when you need the RHOAI manifest map before the same `--maas=` override.

### Where to find the image references

After a successful run:

- **Job summary** on the workflow run lists operator, bundle, and catalog image URLs, plus a **Models-as-a-Service deploy** section with the exact `./scripts/deploy.sh` command (same as below).
- **Job outputs:** `operator_image`, `bundle_image`, `catalog_image`, `version`, `operator_starting_csv`, `maas_deploy_command`, `maas_deploy_snippet` (comments + `deploy.sh` line, including your **bundle** image when using a custom `BUNDLE_REPO`).
- **Artifact:** `build-output-env` (includes `OPERATOR_STARTING_CSV`, `MAAS_DEPLOY_COMMAND`, `MAAS_DEPLOY_SNIPPET`, and `BUNDLE_IMAGE`).

### Why does the log show `***` instead of image names?

Only if those strings still live in **secrets**. Use **repository variables** for `QUAY_REPO`, `QUAY_TAG`, and related fields so full image names appear in the job summary. See [using secrets in GitHub Actions](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions) and [variables](https://docs.github.com/en/actions/learn-github-actions/variables#defining-configuration-variables-for-multiple-workflows).

### Deploy MaaS with your operator images ([Models-as-a-Service](https://opendatahub-io.github.io/models-as-a-service/latest/install/maas-setup/))

The [maas-billing](https://github.com/opendatahub-io/maas-billing) repository ships `scripts/deploy.sh`, which accepts **`--operator-catalog`** (the **catalog/index** image), **`--operator-image`** (the operator container image), and **`--channel`** (use **`fast`** for ODH, matching the operator bundle default). Set **`OPERATOR_STARTING_CSV`** in the environment to the **ClusterServiceVersion** name for this bundle (same as OLM `Subscription` `startingCSV`), e.g. `opendatahub-operator.v3.3.0` — the build writes **`OPERATOR_STARTING_CSV`** in `build-output.env` to match **`VERSION`**. It does **not** take a separate bundle flag: the catalog you built already points at your **OLM bundle** image. The workflow prints a snippet (bundle comment + startingCSV + command) so a custom **`BUNDLE_REPO`** is explicit. After cloning that repo, run from the repository root:

```bash
# OLM bundle image (indexed by the catalog above): '<BUNDLE_IMAGE>'
# Subscription startingCSV (matches bundle CSV): '<OPERATOR_STARTING_CSV>'
OPERATOR_STARTING_CSV='<OPERATOR_STARTING_CSV>' ./scripts/deploy.sh --operator-catalog '<CATALOG_IMAGE>' --operator-image '<OPERATOR_IMAGE>' --channel fast
```

Use `CATALOG_IMAGE`, `OPERATOR_IMAGE`, and `BUNDLE_IMAGE` from `build-output.env` or job outputs (`maas_deploy_snippet` is the full block).

#### OLM channels: `fast` vs `fast-3`

**Channel names are not derived from `VERSION`.** OLM treats a channel as an arbitrary string. Whether your bundle version is `3.3.0`, `4.0.0`, or anything else has **no automatic effect** on whether the channel is called `fast`, `fast-3`, or something else.

This repository runs the upstream **`make bundle-build` / `catalog-build`** flow. For `ODH_PLATFORM_TYPE=OpenDataHub`, the upstream **Makefile** defaults to **`CHANNELS=fast`**, and the **file-based catalog** template (`config/catalog/fbc-basic-template.yaml` and `hack/update-catalog-template.sh`) is written for a channel literally named **`fast`**. So **`--channel fast`** matches what you built.

The **`fast-3`** name appears in upstream’s **community OperatorHub** publishing scripts (for example `prepare-community-bundle.sh`), which **rename** bundle metadata from `fast` to `fast-3` and use a separate release layout. That is **not** the same path as the standard `make catalog-build` this tooling uses. To use `fast-3` end-to-end you would need to align bundle annotations, catalog template, and `update-catalog-template.sh` with the same channel name—upstream does that in their release automation, not via a single `make` variable alone.

## Local build (script)

Clone this repo, install [Go](https://go.dev/) (see upstream `go.mod`), [Podman](https://podman.io/), and `make`. Then set credentials and run:

```bash
export IMAGE_TAG_BASE=quay.io/myorg/opendatahub-operator
export BUNDLE_REPO=quay.io/myorg/odh-operator-bundle  # optional; separate OLM bundle image
export CATALOG_REPO=quay.io/myorg/odh-catalog-index   # optional; separate catalog image
export QUAY_USERNAME=youruser
export QUAY_PASSWORD=yourtoken
export IMG_TAG=latest                    # optional
export OPERATOR_GIT_REF=main             # optional upstream ref
./scripts/build-and-push-odh-operator.sh
cat build-output.env
```

The script writes `build-output.env` at the repository root with `OPERATOR_IMAGE`, `BUNDLE_IMAGE`, `CATALOG_IMAGE`, `IMAGE_TAG_BASE`, optional `CATALOG_REPO`, optional `MAAS_OVERRIDE` (when a MaaS override was applied), `VERSION`, `OPERATOR_STARTING_CSV`, and `MAAS_DEPLOY_COMMAND` / `MAAS_DEPLOY_SNIPPET`. It logs in to each distinct registry hostname found in `IMAGE_TAG_BASE` and `CATALOG_REPO` (same username/password).

### Container commands

#### Using Podman (recommended)

```bash
IMAGE_BUILDER=podman ./scripts/build-and-push-odh-operator.sh
```

#### Docker alternative

```bash
IMAGE_BUILDER=docker ./scripts/build-and-push-odh-operator.sh
```

`IMAGE_BUILDER` is passed through to the upstream `Makefile` as the image tool.

## Upstream documentation

Install, OLM, and cluster requirements are described in the [opendatahub-operator README](https://github.com/opendatahub-io/opendatahub-operator/blob/main/README.md).
