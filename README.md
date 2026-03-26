# Build and deploy ODH operator (Quay)

This repository automates building and pushing the [Open Data Hub operator](https://github.com/opendatahub-io/opendatahub-operator) container image, its OLM **bundle** image, and the **File-Based Catalog** (FBC) **catalog** image to Quay.io. It mirrors the upstream `Makefile` flow (`get-manifests`, `image`, `bundle-build`, `catalog-build`).

## What gets built

The script always builds and pushes the **operator** image, the OLM **bundle** image, and the **catalog** image. You can use one Quay repository base for operator + bundle and a **separate** repository for the catalog index (same credentials; the script logs in to each registry host it needs).

| Output | Image reference |
|--------|-----------------|
| Operator | `$IMAGE_TAG_BASE:$IMG_TAG` |
| Bundle | `$IMAGE_TAG_BASE-bundle:v$VERSION` |
| Catalog | If `CATALOG_REPO` is set: `$CATALOG_REPO:v$VERSION`. Otherwise (upstream default): `$IMAGE_TAG_BASE-catalog:v$VERSION` |

`VERSION` comes from the upstream Makefile unless you override it (see below).

## GitHub Actions

Workflow: [`.github/workflows/build-odh-operator-catalog.yml`](.github/workflows/build-odh-operator-catalog.yml).

### Triggers

- **Push to `main`** — builds and pushes using repository secrets (no manual inputs).
- **Workflow dispatch** — same as above, with optional inputs to override repo, tag, upstream ref, OLM version, or to deploy the bundle to a cluster.

### Required repository secrets

| Secret | Purpose |
|--------|---------|
| `QUAY_USERNAME` | Quay.io user or robot account name |
| `QUAY_PASSWORD` | Quay.io password or robot token |
| `QUAY_REPO` | Operator + bundle image path **without** tag (e.g. `quay.io/myorg/opendatahub-operator`) |
| `QUAY_TAG` | Default tag for the **operator** image (e.g. `latest`). If unset or empty, the script defaults to `latest`. |

### Optional secrets

| Secret | When |
|--------|------|
| `QUAY_CATALOG_REPO` | Catalog index image path **without** tag (e.g. `quay.io/myorg/odh-catalog-index`). If unset, the catalog is pushed to `${QUAY_REPO}-catalog:v$VERSION`. |
| `KUBECONFIG` | Raw kubeconfig file contents, only if you run **workflow dispatch** with **Deploy bundle** enabled |

### Manual run inputs (workflow dispatch)

Leave any field empty to keep using the matching repository secret.

| Input | Meaning |
|-------|---------|
| `image_tag_base` | Overrides `QUAY_REPO` for that run |
| `img_tag` | Overrides `QUAY_TAG` for that run |
| `catalog_repo` | Overrides `QUAY_CATALOG_REPO` for that run |
| `version` | OLM bundle/catalog `VERSION` (empty = upstream Makefile default) |
| `git_ref` | Upstream branch, tag, or commit (default `main`) |
| `deploy_bundle` | After push, run `operator-sdk run bundle` (needs `KUBECONFIG`) |

### Where to find the image references

After a successful run:

- **Job summary** on the workflow run lists operator, bundle, and catalog image URLs.
- **Job outputs:** `operator_image`, `bundle_image`, `catalog_image`, `version`.
- **Artifact:** `build-output-env` (same key/value pairs as `build-output.env`).

## Local build (script)

Clone this repo, install [Go](https://go.dev/) (see upstream `go.mod`), [Podman](https://podman.io/), and `make`. Then set credentials and run:

```bash
export IMAGE_TAG_BASE=quay.io/myorg/opendatahub-operator
export CATALOG_REPO=quay.io/myorg/odh-catalog-index   # optional; separate catalog Quay repo
export QUAY_USERNAME=youruser
export QUAY_PASSWORD=yourtoken
export IMG_TAG=latest                    # optional
export OPERATOR_GIT_REF=main             # optional upstream ref
./scripts/build-and-push-odh-operator.sh
cat build-output.env
```

The script writes `build-output.env` at the repository root with `OPERATOR_IMAGE`, `BUNDLE_IMAGE`, `CATALOG_IMAGE`, `IMAGE_TAG_BASE`, optional `CATALOG_REPO`, and `VERSION`. It logs in to each distinct registry hostname found in `IMAGE_TAG_BASE` and `CATALOG_REPO` (same username/password).

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
