# Build and deploy ODH operator (Quay)

This repository automates building and pushing the [Open Data Hub operator](https://github.com/opendatahub-io/opendatahub-operator) container image, its OLM **bundle** image, and the **File-Based Catalog** (FBC) **catalog** image to Quay.io. It mirrors the upstream `Makefile` flow (`get-manifests`, `image`, `bundle-build`, `catalog-build`).

## What gets built

The script always builds and pushes the **operator** image, the OLM **bundle** image, and the **catalog** image. You can use one Quay repository base for operator + bundle and a **separate** repository for the catalog index (same credentials; the script logs in to each registry host it needs).

| Output | Image reference |
|--------|-----------------|
| Operator | `$IMAGE_TAG_BASE:$IMG_TAG` |
| Bundle | If `BUNDLE_REPO` is set: `$BUNDLE_REPO:<tag>`. Otherwise: `$IMAGE_TAG_BASE-bundle:<tag>` |
| Catalog | If `CATALOG_REPO` is set: `$CATALOG_REPO:<tag>`. Otherwise: `$IMAGE_TAG_BASE-catalog:<tag>` |

**Tag column:** `<tag>` is **`v$VERSION`** by default (same **`VERSION`** as the OLM bundle metadata). If **`UNIFIED_IMAGE_TAG`** is set (`QUAY_UNIFIED_IMAGE_TAG` / workflow **`unified_image_tag`**), **operator**, **bundle**, and **catalog** all use that **same** tag string instead.

**Unified tag (`QUAY_UNIFIED_IMAGE_TAG`) — one value, no extra OLM version needed**

When **`UNIFIED_IMAGE_TAG`** is set, the script **derives** **`VERSION`** for the Makefile / CSV from that tag so the bundle and file-based catalog stay consistent (upstream catalog tooling names bundles from the bundle image tag; it must match **`opendatahub-operator.vX.Y.Z`** in the CSV).

| You set | Images use | Makefile `VERSION` / CSV |
|--------|------------|---------------------------|
| `v3.4.0` | `v3.4.0` | `3.4.0` |
| `3.4.0` | **`v3.4.0`** (normalized) | `3.4.0` |

Accepted forms: **`vX.Y.Z`** or **`X.Y.Z`** (optional patch segment). Arbitrary strings (e.g. `my-branch`) are **rejected** — they break OLM semver and catalog validation.

If **`UNIFIED_IMAGE_TAG`** is set, **`QUAY_OLM_VERSION`** / **`VERSION`** from the environment is **not** used (the unified tag is the single source of truth). Omit **`UNIFIED_IMAGE_TAG`** when you want **`QUAY_OLM_VERSION`** alone to drive **`VERSION`**.

**Versions:**

- **`VERSION`** (from **`QUAY_OLM_VERSION`**, workflow **`version`**, or the [upstream Makefile](https://github.com/opendatahub-io/opendatahub-operator/blob/main/Makefile) default) drives **`make`** and the **CSV** / **`OPERATOR_STARTING_CSV`** when **`UNIFIED_IMAGE_TAG`** is **unset**. Bundle and catalog **image** tags are **`v$VERSION`** unless **`UNIFIED_IMAGE_TAG`** is set.
- **`IMG_TAG`** (from **`QUAY_TAG`** or **`img_tag`**) is the **operator** tag when **`UNIFIED_IMAGE_TAG`** is unset (default **`latest`**). When **`UNIFIED_IMAGE_TAG`** is set, it replaces **`IMG_TAG`** and is also used for bundle and catalog image tags.

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
| `QUAY_TAG` | Operator image tag when **`QUAY_UNIFIED_IMAGE_TAG`** is unset. Default **`latest`**. |
| `QUAY_UNIFIED_IMAGE_TAG` | Optional. One tag for **operator**, **bundle**, and **catalog** — **`vX.Y.Z`** or **`X.Y.Z`**. Derives Makefile **`VERSION`** automatically; images use **`vX.Y.Z`** (bare semver is normalized). Overrides **`QUAY_TAG`** and **`QUAY_OLM_VERSION`** when set. |
| `QUAY_OLM_VERSION` | Optional. OLM **`VERSION`** without a leading **`v`** (e.g. `3.4.0`). Used only when **`QUAY_UNIFIED_IMAGE_TAG`** is unset. |
| `QUAY_BUNDLE_REPO` | Optional. Separate **OLM bundle** image path **without** tag. If unset, bundle is `${QUAY_REPO}-bundle:<tag>`. |
| `QUAY_CATALOG_REPO` | Optional. Separate **catalog** index path **without** tag. If unset, catalog is `${QUAY_REPO}-catalog:<tag>`. |
| `MAAS_MANIFEST_ORG` | Optional. Segment 1 of **`--maas=org:repo:ref:path`**. Default **`opendatahub-io`**. |
| `MAAS_MANIFEST_REPO` | Optional. Segment 2. Default **`maas-billing`**. |
| `MAAS_MANIFEST_REF` | Optional. Segment 3 (branch, tag, or `main@sha`). Default **`main`**. |
| `MAAS_MANIFEST_SOURCE_PATH` | Optional. Segment 4 (folder in repo). Default **`deployment`**. |
| `MAAS_MANIFEST_PIN_LATEST`, `MAAS_MANIFEST_SKIP_FILE_PATCH`, `MAAS_MANIFEST_USE_UPSTREAM_PIN` | Optional; see workflow. Full default **`--maas=`** is **`opendatahub-io:maas-billing:main:deployment`**. |

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
| `img_tag` | Overrides `QUAY_TAG` for that run (ignored when **`unified_image_tag`** is set) |
| `unified_image_tag` | Overrides **`QUAY_UNIFIED_IMAGE_TAG`** — same tag on operator, bundle, and catalog |
| `bundle_repo` | Overrides `QUAY_BUNDLE_REPO` for that run |
| `catalog_repo` | Overrides `QUAY_CATALOG_REPO` for that run |
| `version` | OLM `VERSION` (empty = variable or secret `QUAY_OLM_VERSION`, else Makefile default) |
| `git_ref` | Upstream branch, tag, or commit (default `main`) |
| `deploy_bundle` | After push, run `operator-sdk run bundle` (needs `KUBECONFIG`) |
| `maas_manifest_org` | `MAAS_MANIFEST_ORG` — default **`opendatahub-io`** (segment 1 of `org:repo:ref:path`) |
| `maas_manifest_repo` | `MAAS_MANIFEST_REPO` — default **`maas-billing`** (segment 2) |
| `maas_manifest_ref` | `MAAS_MANIFEST_REF` — default **`main`** (segment 3) |
| `maas_manifest_source_path` | `MAAS_MANIFEST_SOURCE_PATH` — default **`deployment`** (segment 4) |
| `maas_manifest_pin_latest` | Pin `main` to current commit (`main@sha`); needs ref **`main`** |
| `maas_manifest_use_upstream_pin` | Use upstream [`get_all_manifests.sh`](https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh) `["maas"]` pin instead of passing **`--maas=`** |
| `maas_manifest_skip_file_patch` | Set **`MAAS_MANIFEST_SKIP_FILE_PATCH=1`** — do not rewrite `get_all_manifests.sh` on disk |

### Optional MaaS (Models-as-a-Service) manifest source

By default the build script **rewrites the ODH `["maas"]` line in `get_all_manifests.sh` on disk** (only values starting with **`opendatahub-io:`**; the RHOAI block is left unchanged), then passes the same value as **`--maas=`** to [`get_all_manifests.sh`](https://github.com/opendatahub-io/opendatahub-operator/blob/main/get_all_manifests.sh). The default is **`opendatahub-io:maas-billing:main:deployment`**, so the file and the fetch match the **current tip of `main`** from [**maas-billing**](https://github.com/opendatahub-io/maas-billing) under `deployment/`. Use **`MAAS_MANIFEST_SKIP_FILE_PATCH=1`** only if you want **`--maas=`** without editing the file.

- **To use upstream’s pinned `["maas"]` in the file instead** (e.g. `main@<sha>`): set **`MAAS_MANIFEST_USE_UPSTREAM_PIN=1`**. Then **`--maas=`** is not passed.
- **Other repos (e.g. [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service)):** set the four variables so **`--maas=`** becomes e.g. **`opendatahub-io:models-as-a-service:main:deployment`**.
- **Reproducible snapshot of `main`:** **`MAAS_MANIFEST_PIN_LATEST=1`** with **`MAAS_MANIFEST_REF=main`** (resolves to `main@<sha>` via `git ls-remote`).

After **`get_all_manifests.sh`**, the build writes **`manifest-validation/get_all_manifests.sh`** (copy of the upstream map file) and **`manifest-validation/maas-fetch-effective.txt`** (effective **`--maas=`**). The GitHub workflow uploads those as artifact **`get-all-manifests-validation`**. **`build-output.env`** includes **`MANIFEST_VALIDATION_DIR`**.

After a successful fetch with **`--maas=`** (the default path), the script **checks** that `opt/manifests/maas` exists and contains at least one file, and writes **`MAAS_MANIFEST_RESOLVED_REF`** to `build-output.env`.

**`ODH_PLATFORM_TYPE=rhoai`** uses the RHOAI manifest map; the same default **`--maas=`** applies unless **`MAAS_MANIFEST_USE_UPSTREAM_PIN=1`**.

**If a Role or ClusterRole is still wrong after a build:** confirm **`maas-fetch-effective.txt`** shows the expected **`MAAS_OVERRIDE`**, then rebuild the operator, bundle, and catalog and reinstall from the new catalog.

### Where to find the image references

After a successful run:

- **Job summary** on the workflow run lists operator, bundle, and catalog image URLs, plus a **Models-as-a-Service deploy** section with the exact `./scripts/deploy.sh` command (same as below).
- **Job outputs:** `operator_image`, `bundle_image`, `catalog_image`, `version`, `operator_starting_csv`, `maas_deploy_command`, `maas_deploy_snippet` (comments + `deploy.sh` line, including your **bundle** image when using a custom `BUNDLE_REPO`).
- **Artifacts:** `build-output-env` (includes `OPERATOR_STARTING_CSV`, `MAAS_DEPLOY_COMMAND`, `MAAS_DEPLOY_SNIPPET`, `BUNDLE_IMAGE`, `MANIFEST_VALIDATION_DIR`); **`get-all-manifests-validation`** (`manifest-validation/get_all_manifests.sh`, `maas-fetch-effective.txt`).

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
export IMG_TAG=latest                    # optional (ignored if UNIFIED_IMAGE_TAG is set)
# export UNIFIED_IMAGE_TAG=my-build-123  # optional: same tag on operator + bundle + catalog
export OPERATOR_GIT_REF=main             # optional upstream ref
./scripts/build-and-push-odh-operator.sh
cat build-output.env
```

The script writes `build-output.env` at the repository root with `OPERATOR_IMAGE`, `BUNDLE_IMAGE`, `CATALOG_IMAGE`, `IMAGE_TAG_BASE`, optional `UNIFIED_IMAGE_TAG`, optional `CATALOG_REPO`, optional `MAAS_OVERRIDE` (when a MaaS override was applied), `VERSION`, `OPERATOR_STARTING_CSV`, `MANIFEST_VALIDATION_DIR` (unless get-manifests was skipped), and `MAAS_DEPLOY_COMMAND` / `MAAS_DEPLOY_SNIPPET`. Unless **`SKIP_GET_MANIFESTS=1`**, it also writes **`manifest-validation/`** (`get_all_manifests.sh` copy, **`maas-fetch-effective.txt`**). It logs in to each distinct registry hostname found in `IMAGE_TAG_BASE` and `CATALOG_REPO` (same username/password).

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
