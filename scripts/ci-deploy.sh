#!/usr/bin/env bash
set -euo pipefail
: "${IMAGE_TAG:?The build step must supply IMAGE_TAG}"
cluster=${KIND_CLUSTER_NAME:-agent-relay}
context="kind-$cluster"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Export only the host platform to avoid multi-platform digest import errors.
arch=$(docker image inspect "agent-relay:$IMAGE_TAG" --format '{{.Architecture}}')
docker image save --platform "linux/$arch" -o "$scratch/image.tar" "agent-relay:$IMAGE_TAG"
kind load image-archive "$scratch/image.tar" --name "$cluster"

# Render into a temporary directory so a repeated apply never resets the
# live Deployment to the original k8s-v1 image before setting the new tag.
cp k8s/*.yaml "$scratch/"
cat >> "$scratch/kustomization.yaml" <<EOF
images:
  - name: agent-relay
    newTag: $IMAGE_TAG
EOF
kubectl --context "$context" apply -k "$scratch/"
kubectl --context "$context" -n agent-relay rollout status deployment/postgres --timeout=180s
kubectl --context "$context" -n agent-relay rollout status deployment/agent-relay --timeout=180s
kubectl --context "$context" -n agent-relay get deployment agent-relay \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
