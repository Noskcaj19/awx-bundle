# AWX in a Box

Fully self-contained, declarative AWX deployment using **k3d** (Kubernetes in Docker).

> ⚠️ **Internal/dev use only.**

## Pinned Versions

| Component | Version |
|---|---|
| k3s | v1.35.5-k3s1 |
| AWX Operator | 2.19.1 |
| Helm Chart | 3.2.1 |
| AWX | 24.6.1 |

## Prerequisites

- Docker (running)
- [k3d](https://k3d.io/) v5+
- kubectl
- Helm 3
- GNU make

```bash
# CachyOS / Arch
sudo pacman -S docker kubectl helm make
# k3d — install via official script
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

## Quick Start

```bash
cp .env.example .env
# Edit the two required secrets and any corporate settings.
make config-validate
make up
```

The first deployment normally takes 5–15 minutes. Once ready, open
<http://localhost:8080> and use:

```bash
make password
```

To destroy the cluster (including its Kubernetes resources):

```bash
make down
```

PostgreSQL data under `./data/postgres/` remains on the host unless it is
removed separately.

## Configuration

`.env` is shell syntax and is git-ignored. Quote values containing shell
characters such as `&`, `#`, spaces, or `$`. Run `make config-validate` after
each change. Empty optional values preserve the public-image, no-proxy
behavior.

### Image overrides

Every image directly selected by this project can be routed independently.
Repository/tag pairs must either both be empty or both be set; other image
variables take a complete, tagged OCI reference.

| Variable | Upstream/default image |
|---|---|
| `K3D_NODE_IMAGE` | `docker.io/rancher/k3s:v1.35.5-k3s1` |
| `K3D_PROXY_IMAGE` | k3d's version-matched `ghcr.io/k3d-io/k3d-proxy:<version>` |
| `AWX_OPERATOR_IMAGE` | `quay.io/ansible/awx-operator:2.19.1` |
| `KUBE_RBAC_PROXY_IMAGE` | `quay.io/brancz/kube-rbac-proxy:v0.15.0` |
| `AWX_IMAGE_REPOSITORY` + `AWX_IMAGE_TAG` | `quay.io/ansible/awx:24.6.1` |
| `AWX_CONTROL_PLANE_EE_IMAGE` | `quay.io/ansible/awx-ee:24.6.1` |
| `AWX_DEFAULT_EE_IMAGE` | Operator defaults: `quay.io/ansible/awx-ee:latest` and `:24.6.1`; an override registers one managed default |
| `AWX_REDIS_IMAGE_REPOSITORY` + `AWX_REDIS_IMAGE_TAG` | `docker.io/redis:7` |
| `AWX_POSTGRES_IMAGE_REPOSITORY` + `AWX_POSTGRES_IMAGE_TAG` | `quay.io/sclorg/postgresql-15-c9s:latest` |
| `AWX_PROJECTS_INIT_IMAGE` | `quay.io/centos/centos:stream9` |

`K3S_SYSTEM_DEFAULT_REGISTRY` prefixes images owned by k3s itself, including
CoreDNS, pause, local-path provisioner, metrics-server, and other embedded
manifests. Those image names and tags are tied to the selected k3s release.

### Corporate HTTP proxy

Set `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` in `.env`. `NO_PROXY` is
required whenever a proxy is enabled. The loader rejects a global `*` bypass
and automatically adds localhost, k3d host/node connectivity, RFC1918 ranges,
the k3s pod and service CIDRs, `.svc`, and `.svc.cluster.local`.

Both upper- and lower-case proxy variables are applied to:

- host-side Helm repository and install commands;
- the k3d server node, allowing k3s to pass them to containerd and kubelet;
- the AWX Operator manager;
- AWX web, task, rsyslog, and globally managed EE containers;
- `AWX_TASK_ENV` for inventory/project operations and job environments;
- `GALAXY_TASK_ENV` for Galaxy downloads, while retaining AWX's existing
  `ANSIBLE_FORCE_COLOR` and `GIT_SSH_COMMAND` defaults.

`ee_extra_env` does not configure arbitrary custom execution environments.
`AWX_TASK_ENV` covers AWX-managed job launches; externally managed container
groups or custom EE policies may still require their own proxy configuration.
See the [AWX Operator environment documentation](https://docs.ansible.com/projects/awx-operator/en/latest/user-guide/advanced-configuration/exporting-environment-variables-to-containers.html).

### Private registry authentication and CA trust

Use these variables for a private or authenticated registry:

| Variable | Purpose |
|---|---|
| `REGISTRY_SERVER` | Registry hostname and optional port, without `https://` |
| `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` | Optional credentials; both are required together |
| `REGISTRY_CA_FILE` | Optional non-empty PEM CA file mounted into the k3s node |
| `REGISTRY_PULL_SECRET_NAME` | Kubernetes Docker pull secret name |
| `REGISTRY_TLS_VERIFY` | `true` by default; use `false` only for a test registry |

The same credentials produce a Docker config pull secret for operator/AWX
pods and an AWX EE pull-credential secret. k3s receives a protected
`registries.yaml` for containerd. Credentials are never committed; generated
files are mode `0600` and ignored under `k3d/generated/`, `helm/generated/`,
and `k8s/awx/generated/`.

Docker pulls the k3s node and k3d load-balancer images before Kubernetes or
its pull secrets exist. The host Docker daemon must therefore already have the
corporate proxy and CA configured and must be logged in to every registry used
for `K3D_NODE_IMAGE` or `K3D_PROXY_IMAGE`:

```bash
docker login registry.example.test
```

See the [k3d create options](https://k3d.io/v5.8.3/usage/commands/k3d_cluster_create/),
[k3s proxy guidance](https://docs.k3s.io/advanced), and
[k3s private-registry configuration](https://docs.k3s.io/installation/private-registry).

### Corporate CA inside AWX

Set `AWX_CA_BUNDLE_FILE` to a non-empty PEM bundle. It may be the same file as
`REGISTRY_CA_FILE`. The deployment creates `awx-custom-certs` and references
it through `bundle_cacert_secret`, making the CA available to the AWX control
plane and execution environments. A configured file that is missing or empty
is treated as an error rather than silently disabling trust.

## Applying proxy or registry changes

Changes to node proxy variables, `registries.yaml`, registry CA mounts,
`K3D_NODE_IMAGE`, `K3D_PROXY_IMAGE`, or `K3S_SYSTEM_DEFAULT_REGISTRY` only take
effect on a fresh k3d cluster. Recreate it after changing those values:

```bash
make config-validate
make cluster-delete
make cluster-create
make operator-install
make awx-apply
make wait
```

This deletes Kubernetes resources. The host PostgreSQL directory remains, but
take a backup before relying on it across image or version changes.

## Commands

```text
make help                    Show all targets
make check                   Verify local prerequisites
make config-validate         Validate .env without cluster changes
make config-generate         Render protected deployment configuration
make test                    Run offline shell, Helm, and Kustomize tests
make up                      Create the cluster and deploy AWX
make down                    Destroy the k3d cluster
make cluster-create          Create only the k3d cluster
make cluster-delete          Delete only the k3d cluster
make operator-install        Generate config/secrets and install the operator
make operator-uninstall      Uninstall the operator
make registry-secrets-apply  Apply registry pull credentials
make secrets-apply           Apply AWX admin and secret-key secrets
make ca-apply                Apply or remove the AWX corporate CA secret
make awx-apply               Apply the AWX custom resource
make awx-delete              Delete the AWX instance but keep the operator
make wait                    Wait for AWX deployments
make status                  Show AWX resources
make password                Print the AWX admin credentials
make logs-operator           Tail operator logs
make logs-awx                Tail AWX web logs
```

## Architecture

```text
localhost:8080 → k3d port-map → NodePort 30080 → AWX web service
                                                 ├── awx-web (nginx + uwsgi)
                                                 ├── awx-task (celery workers)
                                                 ├── awx-ee (execution environment)
                                                 ├── redis
                                                 └── postgresql (local-path PVC)
```

- Single k3d server with Traefik and ServiceLB disabled.
- AWX Operator installed through Helm; the AWX resource is rendered with
  Kustomize.
- Managed PostgreSQL on k3s `local-path` storage.
- Projects are expected to come from Git/SCM.
- To change the host port, update both `k3d/awx-dev.yaml` and
  `CSRF_TRUSTED_ORIGINS` in `k8s/awx/awx.yaml`.

For a corporate-registry smoke test, inspect `kubectl -n awx get pods -o
jsonpath='{..imageID}'` and run an AWX job that reaches an HTTPS endpoint through
the configured proxy.
