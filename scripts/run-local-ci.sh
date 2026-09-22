#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
workspace=$(cd .. && pwd)
export PATH="$workspace/bin:$workspace/uv-tool/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
export XDG_CACHE_HOME="$workspace/act-cache"
export UV_CACHE_DIR="$workspace/uv-cache"
export UV_PYTHON_INSTALL_DIR="$workspace/python"
if [[ -f "$workspace/kind-kubeconfig" ]]; then
  export KUBECONFIG="$workspace/kind-kubeconfig"
fi
if [[ -f "$workspace/docker-config/config.json" ]]; then
  export DOCKER_CONFIG="$workspace/docker-config"
fi
if [[ -S "$HOME/.docker/run/docker.sock" ]]; then
  export DOCKER_HOST="unix://$HOME/.docker/run/docker.sock"
fi
args=()
for name in PATH KUBECONFIG DOCKER_CONFIG DOCKER_HOST UV_CACHE_DIR UV_PYTHON_INSTALL_DIR; do
  if [[ -n "${!name:-}" ]]; then
    args+=(--env "$name=${!name}")
  fi
done
act push -P ubuntu-latest=-self-hosted --container-architecture linux/arm64 \
  --no-cache-server --action-cache-path "$XDG_CACHE_HOME" "${args[@]}" "$@"
