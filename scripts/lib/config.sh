#!/usr/bin/env bash

# Shared configuration loader, validator, and renderer. This file is sourced by
# deployment scripts so every host-side command sees the same proxy settings.

CONFIG_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ENV_FILE=${ENV_FILE:-"$CONFIG_ROOT/.env"}

die() {
  printf 'Configuration error: %s\n' "$*" >&2
  return 1
}

yaml_quote() {
  local escaped=${1//\'/\'\'}
  printf "'%s'" "$escaped"
}

require_single_line() {
  local name=$1 value=$2
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "$name must be a single-line value"
}

validate_dns_label() {
  local name=$1 value=$2
  [[ $value =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die "$name must be a valid Kubernetes name"
}

validate_repository_tag_pair() {
  local repository_name=$1 tag_name=$2 repository=$3 tag=$4

  if [[ -n $repository || -n $tag ]]; then
    [[ -n $repository && -n $tag ]] || die "$repository_name and $tag_name must be set together"
    [[ $repository != *://* && $repository != *@* && $repository != *[[:space:]]* ]] ||
      die "$repository_name must be an OCI repository without a scheme, digest, or tag"
    [[ $repository =~ ^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)+$ ]] ||
      die "$repository_name is not a valid OCI repository"
    [[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "$tag_name is not a valid OCI tag"
  fi
}

validate_image_ref() {
  local name=$1 value=$2
  [[ -z $value ]] && return 0
  [[ $value != *://* && $value != *[[:space:]]* ]] || die "$name must be an OCI image reference without a scheme"
  [[ $value =~ ^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)+(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127}|@sha256:[A-Fa-f0-9]{64})$ ]] ||
    die "$name must include a valid repository and tag (or sha256 digest)"
}

append_no_proxy() {
  local candidate=$1 item
  [[ -n $candidate ]] || return 0
  IFS=',' read -r -a _no_proxy_items <<< "$NO_PROXY_EFFECTIVE"
  for item in "${_no_proxy_items[@]}"; do
    [[ $item == "$candidate" ]] && return 0
  done
  NO_PROXY_EFFECTIVE=${NO_PROXY_EFFECTIVE:+"$NO_PROXY_EFFECTIVE,"}$candidate
}

load_config() {
  local require_awx_secrets=${1:-true}
  [[ -f $ENV_FILE ]] || die "Missing $ENV_FILE — copy .env.example to .env and edit it"

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${AWX_ADMIN_PASSWORD:=}"
  : "${AWX_SECRET_KEY:=}"
  : "${K3D_NODE_IMAGE:=}"
  : "${K3D_PROXY_IMAGE:=}"
  : "${AWX_OPERATOR_IMAGE:=}"
  : "${KUBE_RBAC_PROXY_IMAGE:=}"
  : "${AWX_IMAGE_REPOSITORY:=}"
  : "${AWX_IMAGE_TAG:=}"
  : "${AWX_CONTROL_PLANE_EE_IMAGE:=}"
  : "${AWX_DEFAULT_EE_IMAGE:=}"
  : "${AWX_REDIS_IMAGE_REPOSITORY:=}"
  : "${AWX_REDIS_IMAGE_TAG:=}"
  : "${AWX_POSTGRES_IMAGE_REPOSITORY:=}"
  : "${AWX_POSTGRES_IMAGE_TAG:=}"
  : "${AWX_PROJECTS_INIT_IMAGE:=}"
  : "${K3S_SYSTEM_DEFAULT_REGISTRY:=}"
  : "${REGISTRY_SERVER:=}"
  : "${REGISTRY_USERNAME:=}"
  : "${REGISTRY_PASSWORD:=}"
  : "${REGISTRY_CA_FILE:=}"
  : "${REGISTRY_PULL_SECRET_NAME:=corporate-registry-pull}"
  : "${REGISTRY_TLS_VERIFY:=true}"
  : "${AWX_CA_BUNDLE_FILE:=}"
  : "${HTTP_PROXY:=}"
  : "${HTTPS_PROXY:=}"
  : "${NO_PROXY:=}"

  if [[ $require_awx_secrets == true ]]; then
    [[ -n $AWX_ADMIN_PASSWORD ]] || die "AWX_ADMIN_PASSWORD is required"
    [[ -n $AWX_SECRET_KEY ]] || die "AWX_SECRET_KEY is required"
  fi

  local name
  for name in HTTP_PROXY HTTPS_PROXY NO_PROXY REGISTRY_USERNAME REGISTRY_PASSWORD; do
    require_single_line "$name" "${!name}"
  done

  validate_repository_tag_pair AWX_IMAGE_REPOSITORY AWX_IMAGE_TAG "$AWX_IMAGE_REPOSITORY" "$AWX_IMAGE_TAG"
  validate_repository_tag_pair AWX_REDIS_IMAGE_REPOSITORY AWX_REDIS_IMAGE_TAG "$AWX_REDIS_IMAGE_REPOSITORY" "$AWX_REDIS_IMAGE_TAG"
  validate_repository_tag_pair AWX_POSTGRES_IMAGE_REPOSITORY AWX_POSTGRES_IMAGE_TAG "$AWX_POSTGRES_IMAGE_REPOSITORY" "$AWX_POSTGRES_IMAGE_TAG"

  for name in K3D_NODE_IMAGE K3D_PROXY_IMAGE AWX_OPERATOR_IMAGE KUBE_RBAC_PROXY_IMAGE \
    AWX_CONTROL_PLANE_EE_IMAGE AWX_DEFAULT_EE_IMAGE AWX_PROJECTS_INIT_IMAGE; do
    validate_image_ref "$name" "${!name}"
  done

  if [[ -n $K3S_SYSTEM_DEFAULT_REGISTRY ]]; then
    [[ $K3S_SYSTEM_DEFAULT_REGISTRY != *://* && $K3S_SYSTEM_DEFAULT_REGISTRY != */ &&
       $K3S_SYSTEM_DEFAULT_REGISTRY =~ ^[a-z0-9._-]+(:[0-9]+)?(/[a-z0-9._-]+)*$ ]] ||
      die "K3S_SYSTEM_DEFAULT_REGISTRY must be a registry host or path prefix without a scheme"
  fi

  if [[ -n $REGISTRY_USERNAME || -n $REGISTRY_PASSWORD ]]; then
    [[ -n $REGISTRY_USERNAME && -n $REGISTRY_PASSWORD ]] ||
      die "REGISTRY_USERNAME and REGISTRY_PASSWORD must be set together"
  fi
  if [[ -n $REGISTRY_USERNAME || -n $REGISTRY_CA_FILE || $REGISTRY_TLS_VERIFY != true ]]; then
    [[ -n $REGISTRY_SERVER ]] || die "REGISTRY_SERVER is required when registry authentication, CA, or TLS options are configured"
  fi
  if [[ -n $REGISTRY_SERVER ]]; then
    [[ $REGISTRY_SERVER != *://* && $REGISTRY_SERVER != */ &&
       $REGISTRY_SERVER =~ ^[A-Za-z0-9._-]+(:[0-9]+)?$ ]] ||
      die "REGISTRY_SERVER must be a registry hostname with an optional port and no scheme"
  fi
  case ${REGISTRY_TLS_VERIFY,,} in
    true|false) REGISTRY_TLS_VERIFY=${REGISTRY_TLS_VERIFY,,} ;;
    *) die "REGISTRY_TLS_VERIFY must be true or false" ;;
  esac
  validate_dns_label REGISTRY_PULL_SECRET_NAME "$REGISTRY_PULL_SECRET_NAME"

  if [[ -n $REGISTRY_CA_FILE ]]; then
    [[ -f $REGISTRY_CA_FILE && -s $REGISTRY_CA_FILE ]] || die "REGISTRY_CA_FILE does not exist or is empty: $REGISTRY_CA_FILE"
    REGISTRY_CA_FILE=$(cd "$(dirname "$REGISTRY_CA_FILE")" && pwd)/$(basename "$REGISTRY_CA_FILE")
  fi
  if [[ -n $AWX_CA_BUNDLE_FILE ]]; then
    [[ -f $AWX_CA_BUNDLE_FILE && -s $AWX_CA_BUNDLE_FILE ]] || die "AWX_CA_BUNDLE_FILE does not exist or is empty: $AWX_CA_BUNDLE_FILE"
    AWX_CA_BUNDLE_FILE=$(cd "$(dirname "$AWX_CA_BUNDLE_FILE")" && pwd)/$(basename "$AWX_CA_BUNDLE_FILE")
  fi

  if [[ -n $HTTP_PROXY || -n $HTTPS_PROXY ]]; then
    [[ -n $NO_PROXY ]] || die "NO_PROXY is required when HTTP_PROXY or HTTPS_PROXY is configured"
    IFS=',' read -r -a _configured_no_proxy <<< "$NO_PROXY"
    for name in "${_configured_no_proxy[@]}"; do
      [[ $name != '*' ]] || die "NO_PROXY must not contain * because it bypasses the proxy for every destination"
    done
    NO_PROXY_EFFECTIVE=$NO_PROXY
    for name in localhost 127.0.0.1 ::1 host.k3d.internal host.docker.internal \
      k3d-awx-dev-server-0 10.42.0.0/16 10.43.0.0/16 10.0.0.0/8 \
      172.16.0.0/12 192.168.0.0/16 .svc .svc.cluster.local; do
      append_no_proxy "$name"
    done
    NO_PROXY=$NO_PROXY_EFFECTIVE
  fi

  http_proxy=$HTTP_PROXY
  https_proxy=$HTTPS_PROXY
  no_proxy=$NO_PROXY
  export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  export AWX_ADMIN_PASSWORD AWX_SECRET_KEY K3D_NODE_IMAGE K3D_PROXY_IMAGE
  export AWX_OPERATOR_IMAGE KUBE_RBAC_PROXY_IMAGE AWX_IMAGE_REPOSITORY AWX_IMAGE_TAG
  export AWX_CONTROL_PLANE_EE_IMAGE AWX_DEFAULT_EE_IMAGE
  export AWX_REDIS_IMAGE_REPOSITORY AWX_REDIS_IMAGE_TAG
  export AWX_POSTGRES_IMAGE_REPOSITORY AWX_POSTGRES_IMAGE_TAG AWX_PROJECTS_INIT_IMAGE
  export K3S_SYSTEM_DEFAULT_REGISTRY REGISTRY_SERVER REGISTRY_USERNAME REGISTRY_PASSWORD
  export REGISTRY_CA_FILE REGISTRY_PULL_SECRET_NAME REGISTRY_TLS_VERIFY AWX_CA_BUNDLE_FILE
}

emit_proxy_env() {
  local indent=$1 upper lower value
  for upper in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    value=${!upper}
    [[ -n $value ]] || continue
    printf '%s- name: %s\n%s  value: ' "$indent" "$upper" "$indent"
    yaml_quote "$value"
    printf '\n'
    lower=${upper,,}
    printf '%s- name: %s\n%s  value: ' "$indent" "$lower" "$indent"
    yaml_quote "$value"
    printf '\n'
  done
}

emit_proxy_mapping() {
  local indent=$1 upper lower value
  for upper in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    value=${!upper}
    [[ -n $value ]] || continue
    printf '%s%s: ' "$indent" "$upper"
    yaml_quote "$value"
    printf '\n'
    lower=${upper,,}
    printf '%s%s: ' "$indent" "$lower"
    yaml_quote "$value"
    printf '\n'
  done
}

render_helm_values() {
  local output=$1 has_values=false
  mkdir -p "$(dirname "$output")"
  umask 077
  : > "$output"

  if [[ -n $REGISTRY_USERNAME ]]; then
    cat >> "$output" <<EOF
operator-controller:
  spec:
    template:
      spec:
        imagePullSecrets:
          - name: $(yaml_quote "$REGISTRY_PULL_SECRET_NAME")
EOF
    has_values=true
  fi

  if [[ -n $AWX_OPERATOR_IMAGE || -n $HTTP_PROXY || -n $HTTPS_PROXY ]]; then
    cat >> "$output" <<'EOF'
operator-controller-containers:
  awx-manager:
EOF
    if [[ -n $AWX_OPERATOR_IMAGE ]]; then
      {
        printf '    image: '
        yaml_quote "$AWX_OPERATOR_IMAGE"
        printf '\n'
      } >> "$output"
    fi
    if [[ -n $HTTP_PROXY || -n $HTTPS_PROXY ]]; then
      cat >> "$output" <<'EOF'
    env:
      - name: ANSIBLE_GATHERING
        value: explicit
      - name: ANSIBLE_DEBUG_LOGS
        value: "false"
      - name: WATCH_NAMESPACE
        valueFrom:
          fieldRef:
            fieldPath: metadata.namespace
EOF
      emit_proxy_env '      ' >> "$output"
    fi
    has_values=true
  fi

  if [[ -n $KUBE_RBAC_PROXY_IMAGE ]]; then
    if [[ $has_values == false || ! -s $output ]] || ! grep -q '^operator-controller-containers:' "$output"; then
      printf 'operator-controller-containers:\n' >> "$output"
    fi
    {
      printf '  kube-rbac-proxy:\n    image: '
      yaml_quote "$KUBE_RBAC_PROXY_IMAGE"
      printf '\n'
    } >> "$output"
    has_values=true
  fi

  [[ $has_values == true ]] || printf '{}\n' > "$output"
  chmod 600 "$output"
}

render_awx_overlay() {
  local output=$1 has_spec=false key
  mkdir -p "$(dirname "$output")"
  umask 077
  {
    echo "# Auto-generated by 'make config-generate' — do not edit by hand."
    echo 'apiVersion: awx.ansible.com/v1beta1'
    echo 'kind: AWX'
    echo 'metadata:'
    echo '  name: awx'
    echo 'spec:'

    if [[ -n $AWX_CA_BUNDLE_FILE ]]; then
      echo '  bundle_cacert_secret: awx-custom-certs'
      has_spec=true
    fi
    if [[ -n $AWX_IMAGE_REPOSITORY ]]; then
      printf '  image: '; yaml_quote "$AWX_IMAGE_REPOSITORY"; printf '\n'
      printf '  image_version: '; yaml_quote "$AWX_IMAGE_TAG"; printf '\n'
      has_spec=true
    fi
    if [[ -n $AWX_CONTROL_PLANE_EE_IMAGE ]]; then
      printf '  control_plane_ee_image: '; yaml_quote "$AWX_CONTROL_PLANE_EE_IMAGE"; printf '\n'
      has_spec=true
    fi
    if [[ -n $AWX_DEFAULT_EE_IMAGE ]]; then
      echo '  ee_images:'
      echo "    - name: 'AWX EE (default)'"
      printf '      image: '; yaml_quote "$AWX_DEFAULT_EE_IMAGE"; printf '\n'
      has_spec=true
    fi
    if [[ -n $AWX_REDIS_IMAGE_REPOSITORY ]]; then
      printf '  redis_image: '; yaml_quote "$AWX_REDIS_IMAGE_REPOSITORY"; printf '\n'
      printf '  redis_image_version: '; yaml_quote "$AWX_REDIS_IMAGE_TAG"; printf '\n'
      has_spec=true
    fi
    if [[ -n $AWX_POSTGRES_IMAGE_REPOSITORY ]]; then
      printf '  postgres_image: '; yaml_quote "$AWX_POSTGRES_IMAGE_REPOSITORY"; printf '\n'
      printf '  postgres_image_version: '; yaml_quote "$AWX_POSTGRES_IMAGE_TAG"; printf '\n'
      has_spec=true
    fi
    if [[ -n $AWX_PROJECTS_INIT_IMAGE ]]; then
      printf '  init_projects_container_image: '; yaml_quote "$AWX_PROJECTS_INIT_IMAGE"; printf '\n'
      has_spec=true
    fi
    if [[ -n $REGISTRY_USERNAME ]]; then
      echo '  image_pull_secrets:'
      printf '    - '; yaml_quote "$REGISTRY_PULL_SECRET_NAME"; printf '\n'
      echo '  ee_pull_credentials_secret: awx-ee-registry-credentials'
      has_spec=true
    fi
    if [[ -n $HTTP_PROXY || -n $HTTPS_PROXY ]]; then
      for key in ee_extra_env task_extra_env web_extra_env rsyslog_extra_env; do
        printf '  %s: |\n' "$key"
        emit_proxy_env '    '
      done
      echo '  extra_settings:'
      echo '    - setting: CSRF_TRUSTED_ORIGINS'
      echo "      value: \"['http://localhost:8080']\""
      echo '    - setting: AWX_TASK_ENV'
      echo '      value:'
      emit_proxy_mapping '        '
      echo '    - setting: GALAXY_TASK_ENV'
      echo '      value:'
      echo "        ANSIBLE_FORCE_COLOR: 'false'"
      echo "        GIT_SSH_COMMAND: 'ssh -o StrictHostKeyChecking=no'"
      emit_proxy_mapping '        '
      has_spec=true
    fi
  } > "$output"

  if [[ $has_spec == false ]]; then
    # Replace the final mapping with the no-op form expected by kustomize.
    sed -i '$s/^spec:$/spec: {}/' "$output"
  fi
  chmod 600 "$output"
}

render_registries() {
  local output=$1 endpoint
  mkdir -p "$(dirname "$output")"
  if [[ -z $REGISTRY_SERVER ]]; then
    rm -f "$output"
    return 0
  fi

  endpoint=https://$REGISTRY_SERVER
  umask 077
  {
    echo 'mirrors:'
    printf '  '; yaml_quote "$REGISTRY_SERVER"; echo ':'
    echo '    endpoint:'
    printf '      - '; yaml_quote "$endpoint"; printf '\n'
    if [[ -n $REGISTRY_USERNAME || -n $REGISTRY_CA_FILE || $REGISTRY_TLS_VERIFY == false ]]; then
      echo 'configs:'
      printf '  '; yaml_quote "$REGISTRY_SERVER"; echo ':'
      if [[ -n $REGISTRY_USERNAME ]]; then
        echo '    auth:'
        printf '      username: '; yaml_quote "$REGISTRY_USERNAME"; printf '\n'
        printf '      password: '; yaml_quote "$REGISTRY_PASSWORD"; printf '\n'
      fi
      if [[ -n $REGISTRY_CA_FILE || $REGISTRY_TLS_VERIFY == false ]]; then
        echo '    tls:'
        if [[ -n $REGISTRY_CA_FILE ]]; then
          echo "      ca_file: '/etc/rancher/k3s/registry-ca.crt'"
        fi
        if [[ $REGISTRY_TLS_VERIFY == false ]]; then
          echo '      insecure_skip_verify: true'
        fi
      fi
    fi
  } > "$output"
  chmod 600 "$output"
}

render_config() {
  local helm_output=${HELM_OVERRIDE_FILE:-"$CONFIG_ROOT/helm/generated/awx-operator-overrides.yaml"}
  local awx_output=${AWX_OVERLAY_FILE:-"$CONFIG_ROOT/k8s/awx/generated/overlay-patch.yaml"}
  local registry_output=${REGISTRIES_FILE:-"$CONFIG_ROOT/k3d/generated/registries.yaml"}
  render_helm_values "$helm_output"
  render_awx_overlay "$awx_output"
  render_registries "$registry_output"
}
