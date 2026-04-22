# AWX in a Box

Fully self-contained, declarative AWX deployment using **k3d** (Kubernetes in Docker).

> ⚠️ **Internal/dev use only.**

## Pinned Versions

| Component        | Version    |
|------------------|------------|
| k3s              | v1.30.3    |
| AWX Operator     | 2.19.1     |
| Helm Chart       | 3.2.1      |
| AWX              | 24.6.1     |

## Prerequisites

- Docker (running)
- [k3d](https://k3d.io/) v5+
- kubectl
- Helm 3
- make

```bash
# CachyOS / Arch
sudo pacman -S docker kubectl helm make
# k3d — install via official script
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
```

## Quick Start

```bash
cp .env.example .env   # edit secrets as needed
make up                # create cluster + deploy AWX (5-15 min first run)
```

Once ready, open **http://localhost:8080** and log in:

```bash
make password  # print admin credentials
```

## Teardown

```bash
make down      # destroys cluster and ALL data
```

## Available Commands

```
make help             Show all targets
make up               Create cluster and deploy AWX
make down             Destroy the k3d cluster
make status           Show pod/service/PVC status
make password         Print admin credentials
make url              Print AWX URL
make logs-operator    Tail operator logs
make logs-awx         Tail AWX web logs
```

### Granular Targets

```
make check            Verify prerequisites
make cluster-create   Create k3d cluster only
make cluster-delete   Delete k3d cluster only
make operator-install Install AWX operator via Helm
make secrets-apply    Create K8s secrets from .env
make awx-apply        Apply AWX custom resource
make awx-delete       Delete AWX instance (keeps operator)
make wait             Wait for AWX pods to be ready
```

## Architecture

```
localhost:8080 → k3d port-map → NodePort 30080 → AWX web service
                                                 ├── awx-web (nginx + uwsgi)
                                                 ├── awx-task (celery workers)
                                                 ├── awx-ee (execution environment)
                                                 ├── redis
                                                 └── postgresql (managed, local-path PVC)
```

- **Single k3d node** with Traefik/ServiceLB disabled (not needed)
- **AWX Operator** installed via Helm chart, AWX instance via Kustomize
- **Managed PostgreSQL** on k3s `local-path` storage provisioner

## Configuration

Secrets are stored in `.env` (git-ignored). Copy `.env.example` to get started:

| Variable             | Purpose                          |
|----------------------|----------------------------------|
| `AWX_ADMIN_PASSWORD` | AWX web UI admin password        |
| `AWX_SECRET_KEY`     | Django secret key (keep stable)  |

## Notes

- First boot pulls ~3GB of images — be patient
- PostgreSQL data is persisted to `./data/storage/` on the host and survives `make down`
- Projects are expected to come from Git/SCM (no local project persistence)
- To change the host port, update both `k3d/awx-dev.yaml` and `CSRF_TRUSTED_ORIGINS` in `k8s/awx/awx.yaml`
