#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1 pattern=$2
  rg -q -- "$pattern" "$file" || fail "$file does not contain: $pattern"
}

assert_not_contains() {
  local file=$1 pattern=$2
  ! rg -q -- "$pattern" "$file" || fail "$file unexpectedly contains: $pattern"
}

render_fixture() {
  local env_file=$1 output_dir=$2 output
  mkdir -p "$output_dir/awx/generated" "$output_dir/helm" "$output_dir/k3d"
  cp k8s/awx/awx.yaml k8s/awx/kustomization.yaml "$output_dir/awx/"
  output=$(ENV_FILE=$env_file \
    HELM_OVERRIDE_FILE="$output_dir/helm/overrides.yaml" \
    AWX_OVERLAY_FILE="$output_dir/awx/generated/overlay-patch.yaml" \
    REGISTRIES_FILE="$output_dir/k3d/registries.yaml" \
    ./scripts/configure.sh render)
  [[ $output == '✓ Generated protected k3d, Helm, and AWX configuration' ]] ||
    fail "config renderer printed unexpected (potentially sensitive) output"
}

expect_invalid() {
  local env_file=$1 expected=$2 output
  if output=$(ENV_FILE=$env_file ./scripts/configure.sh validate 2>&1); then
    fail "configuration unexpectedly passed validation: $env_file"
  fi
  [[ $output == *"$expected"* ]] || fail "expected validation error containing '$expected', got: $output"
}

for script in scripts/*.sh scripts/lib/*.sh tests/*.sh up.sh down.sh; do
  bash -n "$script"
done

# Empty optional configuration must retain the chart and CR defaults.
cp .env.example "$TMP/default.env"
render_fixture "$TMP/default.env" "$TMP/default"
[[ $(<"$TMP/default/helm/overrides.yaml") == '{}' ]] || fail 'default Helm overrides are not empty'
[[ ! -e $TMP/default/k3d/registries.yaml ]] || fail 'default registry configuration should not exist'
assert_contains "$TMP/default/awx/generated/overlay-patch.yaml" '^spec: \{\}$'
assert_not_contains "$TMP/default/awx/generated/overlay-patch.yaml" 'image:|HTTP_PROXY|image_pull_secrets'
kubectl kustomize "$TMP/default/awx" > "$TMP/default-awx.yaml"
assert_contains "$TMP/default-awx.yaml" 'CSRF_TRUSTED_ORIGINS'

helm template awx-operator awx-operator/awx-operator --version 3.2.1 --namespace awx \
  -f helm/awx-operator-values.yaml -f "$TMP/default/helm/overrides.yaml" > "$TMP/default-helm.yaml"
assert_contains "$TMP/default-helm.yaml" 'quay.io/ansible/awx-operator:2.19.1'
assert_contains "$TMP/default-helm.yaml" 'quay.io/brancz/kube-rbac-proxy:v0.15.0'
assert_not_contains "$TMP/default-helm.yaml" 'HTTP_PROXY|corporate-registry-pull'

# Fully populated config exercises YAML quoting, every image, proxy propagation,
# private registry auth/CA, and restrictive generated-file permissions.
printf '%s\n' 'test corporate CA' > "$TMP/corporate-ca.crt"
cat > "$TMP/full.env" <<EOF
AWX_ADMIN_PASSWORD='Admin p@ss!&%'
AWX_SECRET_KEY='0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN'
K3D_NODE_IMAGE='registry.example.test/platform/k3s:v1.35.5-k3s1'
K3D_PROXY_IMAGE='registry.example.test/platform/k3d-proxy:5.8.3'
AWX_OPERATOR_IMAGE='registry.example.test/ansible/awx-operator:2.19.1'
KUBE_RBAC_PROXY_IMAGE='registry.example.test/platform/kube-rbac-proxy:v0.15.0'
AWX_IMAGE_REPOSITORY='registry.example.test/ansible/awx'
AWX_IMAGE_TAG='24.6.1'
AWX_CONTROL_PLANE_EE_IMAGE='registry.example.test/ansible/awx-ee:24.6.1'
AWX_DEFAULT_EE_IMAGE='registry.example.test/ansible/default-ee:24.6.1'
AWX_REDIS_IMAGE_REPOSITORY='registry.example.test/library/redis'
AWX_REDIS_IMAGE_TAG='7'
AWX_POSTGRES_IMAGE_REPOSITORY='registry.example.test/sclorg/postgresql-15-c9s'
AWX_POSTGRES_IMAGE_TAG='latest'
AWX_PROJECTS_INIT_IMAGE='registry.example.test/centos/centos:stream9'
K3S_SYSTEM_DEFAULT_REGISTRY='registry.example.test/k3s'
HTTP_PROXY='http://proxy-user:p@ss!%26&@proxy.example.test:8080'
HTTPS_PROXY='http://proxy-user:p@ss!%26&@proxy.example.test:8080'
NO_PROXY='internal.example.test'
REGISTRY_SERVER='registry.example.test'
REGISTRY_USERNAME='robot-user'
REGISTRY_PASSWORD='r3g:p@ss!%26&word'
REGISTRY_CA_FILE='$TMP/corporate-ca.crt'
REGISTRY_PULL_SECRET_NAME='corporate-registry-pull'
REGISTRY_TLS_VERIFY=true
AWX_CA_BUNDLE_FILE='$TMP/corporate-ca.crt'
EOF

render_fixture "$TMP/full.env" "$TMP/full"
for file in "$TMP/full/helm/overrides.yaml" "$TMP/full/awx/generated/overlay-patch.yaml" "$TMP/full/k3d/registries.yaml"; do
  [[ $(stat -c '%a' "$file") == 600 ]] || fail "$file does not have mode 600"
done

helm template awx-operator awx-operator/awx-operator --version 3.2.1 --namespace awx \
  -f helm/awx-operator-values.yaml -f "$TMP/full/helm/overrides.yaml" \
  -f "$TMP/full/k3d/registries.yaml" > "$TMP/full-helm.yaml"
for pattern in \
  'registry.example.test/ansible/awx-operator:2.19.1' \
  'registry.example.test/platform/kube-rbac-proxy:v0.15.0' \
  'name: ANSIBLE_GATHERING' 'name: ANSIBLE_DEBUG_LOGS' 'name: WATCH_NAMESPACE' \
  'name: HTTP_PROXY' 'name: http_proxy' 'name: corporate-registry-pull'; do
  assert_contains "$TMP/full-helm.yaml" "$pattern"
done
assert_not_contains "$TMP/full-helm.yaml" 'r3g:p@ss'

kubectl kustomize "$TMP/full/awx" > "$TMP/full-awx.yaml"
for pattern in \
  'registry.example.test/ansible/awx' 'image_version: 24.6.1' \
  'registry.example.test/ansible/awx-ee:24.6.1' \
  'registry.example.test/ansible/default-ee:24.6.1' \
  'registry.example.test/library/redis' 'redis_image_version: "7"' \
  'registry.example.test/sclorg/postgresql-15-c9s' \
  'registry.example.test/centos/centos:stream9' \
  'bundle_cacert_secret: awx-custom-certs' 'corporate-registry-pull' \
  'ee_pull_credentials_secret: awx-ee-registry-credentials' \
  'rsyslog_extra_env' 'AWX_TASK_ENV' 'GALAXY_TASK_ENV' \
  'ANSIBLE_FORCE_COLOR' 'GIT_SSH_COMMAND' 'host.k3d.internal' '.svc.cluster.local'; do
  assert_contains "$TMP/full-awx.yaml" "$pattern"
done
assert_not_contains "$TMP/full-awx.yaml" 'r3g:p@ss'
assert_contains "$TMP/full/k3d/registries.yaml" "username: 'robot-user'"
assert_contains "$TMP/full/k3d/registries.yaml" "ca_file: '/etc/rancher/k3s/registry-ca.crt'"

# Capture the k3d invocation without starting Docker. This checks the supported
# node env, registry config, CA mount, system registry, and bootstrap overrides.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/k3d" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == cluster && $2 == list ]]; then
  exit 0
fi
printf '%s\n' "$K3D_IMAGE_LOADBALANCER" > "$K3D_LB_LOG"
printf '%s\n' "$@" > "$K3D_ARGS_LOG"
EOF
chmod +x "$TMP/fakebin/k3d"
cluster_output=$(PATH="$TMP/fakebin:$PATH" K3D_ARGS_LOG="$TMP/k3d-args" K3D_LB_LOG="$TMP/k3d-lb" \
  ENV_FILE="$TMP/full.env" HELM_OVERRIDE_FILE="$TMP/cluster-helm.yaml" \
  AWX_OVERLAY_FILE="$TMP/cluster-awx.yaml" REGISTRIES_FILE="$TMP/cluster-registries.yaml" \
  ./scripts/cluster-create.sh)
[[ $cluster_output != *'p@ss'* ]] || fail 'cluster creation printed proxy credentials'
for pattern in \
  '--image' 'registry.example.test/platform/k3s:v1.35.5-k3s1' \
  '--registry-config' "$TMP/cluster-registries.yaml" \
  'HTTP_PROXY=http://proxy-user:p@ss!%26&@proxy.example.test:8080@server:0' \
  'http_proxy=http://proxy-user:p@ss!%26&@proxy.example.test:8080@server:0' \
  '--system-default-registry=registry.example.test/k3s@server:0' \
  "$TMP/corporate-ca.crt:/etc/rancher/k3s/registry-ca.crt@server:0"; do
  assert_contains "$TMP/k3d-args" "$pattern"
done
assert_contains "$TMP/k3d-lb" 'registry.example.test/platform/k3d-proxy:5.8.3'

# Debug logging must identify context/authentication and apply phases without
# echoing registry passwords or credential-bearing proxy URLs.
cp "$TMP/full.env" "$TMP/debug.env"
cat >> "$TMP/debug.env" <<'EOF'
DEBUG_LOGGING=true
KUBECTL_VERBOSITY=6
EOF
cat > "$TMP/fakebin/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --v=* ]]; then
  shift
fi
if [[ ${1:-} == -n ]]; then
  shift 2
fi
case "${1:-} ${2:-}" in
  'config current-context') echo 'k3d-awx-dev' ;;
  'config view')
    if [[ $* == *'.clusters[0].cluster.server'* ]]; then
      printf 'https://127.0.0.1:6550'
    else
      printf 'k3d-awx-dev'
    fi
    ;;
  'version --client=true') echo '  gitVersion: v1.35.0' ;;
  'auth whoami') echo 'Username: debug-user' ;;
  'create namespace'|'create secret')
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: awx\n'
    ;;
  'apply -f')
    cat >/dev/null
    echo 'applied'
    ;;
  *) echo "unexpected fake kubectl invocation" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/fakebin/kubectl"
debug_output=$(PATH="$TMP/fakebin:$PATH" ENV_FILE="$TMP/debug.env" ./scripts/registry-secrets.sh 2>&1)
for pattern in \
  '[debug] Kubernetes context: k3d-awx-dev' \
  '[debug] Kubernetes API server: https://127.0.0.1:6550' \
  "[debug] Checking API authentication with 'kubectl auth whoami'" \
  '[debug] kubectl phase: applying namespace awx' \
  '[debug] kubectl phase: applying registry pull secret corporate-registry-pull'; do
  [[ $debug_output == *"$pattern"* ]] || fail "debug output does not contain: $pattern"
done
[[ $debug_output != *'r3g:p@ss'* ]] || fail 'debug output leaked the registry password'
[[ $debug_output != *'proxy-user'* ]] || fail 'debug output leaked proxy credentials'

# Focused failure cases.
cp "$TMP/default.env" "$TMP/partial-credentials.env"
cat >> "$TMP/partial-credentials.env" <<'EOF'
REGISTRY_SERVER=registry.example.test
REGISTRY_USERNAME=robot
EOF
expect_invalid "$TMP/partial-credentials.env" 'REGISTRY_USERNAME and REGISTRY_PASSWORD must be set together'

cp "$TMP/default.env" "$TMP/missing-ca.env"
cat >> "$TMP/missing-ca.env" <<'EOF'
REGISTRY_SERVER=registry.example.test
REGISTRY_CA_FILE=/definitely/missing/corporate-ca.crt
EOF
expect_invalid "$TMP/missing-ca.env" 'REGISTRY_CA_FILE does not exist or is empty'

cp "$TMP/default.env" "$TMP/partial-image.env"
cat >> "$TMP/partial-image.env" <<'EOF'
AWX_IMAGE_REPOSITORY=registry.example.test/ansible/awx
EOF
expect_invalid "$TMP/partial-image.env" 'AWX_IMAGE_REPOSITORY and AWX_IMAGE_TAG must be set together'

cp "$TMP/default.env" "$TMP/invalid-image.env"
cat >> "$TMP/invalid-image.env" <<'EOF'
AWX_REDIS_IMAGE_REPOSITORY=https://registry.example.test/library/redis:7
AWX_REDIS_IMAGE_TAG=7
EOF
expect_invalid "$TMP/invalid-image.env" 'AWX_REDIS_IMAGE_REPOSITORY must be an OCI repository'

cp "$TMP/default.env" "$TMP/missing-secret.env"
cat >> "$TMP/missing-secret.env" <<'EOF'
AWX_SECRET_KEY=
EOF
expect_invalid "$TMP/missing-secret.env" 'AWX_SECRET_KEY is required'

cp "$TMP/default.env" "$TMP/missing-no-proxy.env"
cat >> "$TMP/missing-no-proxy.env" <<'EOF'
HTTPS_PROXY=http://proxy.example.test:8080
NO_PROXY=
EOF
expect_invalid "$TMP/missing-no-proxy.env" 'NO_PROXY is required'

cp "$TMP/default.env" "$TMP/unsafe-debug.env"
cat >> "$TMP/unsafe-debug.env" <<'EOF'
DEBUG_LOGGING=true
KUBECTL_VERBOSITY=8
EOF
expect_invalid "$TMP/unsafe-debug.env" 'KUBECTL_VERBOSITY must be an integer from 0 through 6'

echo '✓ Configuration, Helm, and Kustomize tests passed'
