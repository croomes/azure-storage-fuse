#!/bin/bash
#
# Deploy the Tachyon cache-server Helm chart into the local kind cluster.
#
# Two charts are installed in order, both pulled from an OCI-enabled ACR:
#   1. cache-server-prereq  - CRDs / RBAC / cluster-scoped resources the main
#                              chart depends on. Pinned to the same version as
#                              the main chart.
#   2. cache-server         - the actual StatefulSet + Service.
#
# Overrides we set on top of the main chart's baked-in values.yaml:
#   * cacheServer.image.repository / .tag  - use the ACR-hosted image
#   * cacheServer.numServers               - match CACHE_SERVER_REPLICAS
#   * cacheServer.scheduler.enabled=false  - blobfuse2 E2E tests do NOT need
#                                             the scheduler component
#
# Image side-load note: we `docker save` the image and drive
# `ctr images import` on each kind node directly. We do NOT use `kind load`
# (either variant) because it hardcodes `ctr images import --all-platforms`,
# which fails with `ctr: content digest ...: not found` when the archive
# from Docker's containerd image store references platforms whose blobs
# weren't pulled.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared configuration
CONFIG_FILE="$SCRIPT_DIR/config/nightly.config"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=./config/nightly.config
    source "$CONFIG_FILE"
    echo "Loaded config from: $CONFIG_FILE"
fi

# --- Required inputs -------------------------------------------------------

if [[ -z "${CACHE_SERVER_IMAGE_REGISTRY:-}" ]]; then
    echo "ERROR: CACHE_SERVER_IMAGE_REGISTRY is empty." >&2
    echo "       Set CACHE_SERVER_IMAGE_REGISTRY / _REPO / _TAG and" >&2
    echo "       CACHE_SERVER_CHART_REGISTRY / _REPO / _VERSION (typically via" >&2
    echo "       the NightlyBlobFuse pipeline variable group) before running." >&2
    exit 1
fi

# CACHE_SERVER_CHART_REGISTRY defaults to the image registry (see
# nightly.config), but that default only kicks in when the config was sourced
# with CACHE_SERVER_IMAGE_REGISTRY already set. In the pipeline the ADO
# variable can be an empty string ('' in YAML), which suppresses the default
# and leaves CACHE_SERVER_CHART_REGISTRY empty even after we've established
# CACHE_SERVER_IMAGE_REGISTRY above. Re-apply the fallback here.
: "${CACHE_SERVER_CHART_REGISTRY:=$CACHE_SERVER_IMAGE_REGISTRY}"

# Empty _TAG / _CHART_VERSION mean "resolve latest from ACR at runtime".
# This lets the nightly pipeline always exercise whatever cache-server /
# chart build is currently published, without needing a pipeline edit
# every time a new version drops.
NEED_ACR_RESOLVE=false
if [[ -z "${CACHE_SERVER_IMAGE_TAG:-}" ]]; then
    NEED_ACR_RESOLVE=true
fi
if [[ -z "${CACHE_SERVER_CHART_VERSION:-}" ]]; then
    NEED_ACR_RESOLVE=true
fi

if [[ "$NEED_ACR_RESOLVE" == "true" ]]; then
    if ! command -v az >/dev/null 2>&1; then
        echo "ERROR: az CLI not found; cannot resolve latest tag from ACR." >&2
        echo "       Either install az (and run 'az login') or set" >&2
        echo "       CACHE_SERVER_IMAGE_TAG and CACHE_SERVER_CHART_VERSION" >&2
        echo "       explicitly." >&2
        exit 1
    fi
fi

# Resolve latest image tag if not pinned. `az acr repository show-tags` uses
# time-based ordering (`time_desc` = newest push first), which matches how
# the Tachyon ACR publishes sequential CI builds.
if [[ -z "${CACHE_SERVER_IMAGE_TAG:-}" ]]; then
    ACR_NAME_FOR_IMAGE="${CACHE_SERVER_IMAGE_REGISTRY%%.*}"
    echo "Resolving latest image tag for $CACHE_SERVER_IMAGE_REGISTRY/$CACHE_SERVER_IMAGE_REPO ..."
    CACHE_SERVER_IMAGE_TAG="$(az acr repository show-tags \
        --name "$ACR_NAME_FOR_IMAGE" \
        --repository "$CACHE_SERVER_IMAGE_REPO" \
        --orderby time_desc --top 1 --output tsv 2>/dev/null || true)"
    if [[ -z "$CACHE_SERVER_IMAGE_TAG" ]]; then
        echo "ERROR: failed to resolve latest tag for" \
             "$CACHE_SERVER_IMAGE_REGISTRY/$CACHE_SERVER_IMAGE_REPO from ACR." >&2
        echo "       Confirm 'az login' + AcrPull on the registry, or set" >&2
        echo "       CACHE_SERVER_IMAGE_TAG explicitly." >&2
        exit 1
    fi
    echo "Resolved latest image tag: $CACHE_SERVER_IMAGE_TAG"
fi

# Resolve latest chart version if not pinned. Chart versions in OCI ACRs are
# stored as artifact tags on the chart repository, so the same `show-tags`
# query works. We pull the latest tag for the main cache-server chart and use
# it for the prereq chart too (contract: they are published in lockstep).
if [[ -z "${CACHE_SERVER_CHART_VERSION:-}" ]]; then
    ACR_NAME_FOR_CHART="${CACHE_SERVER_CHART_REGISTRY%%.*}"
    echo "Resolving latest chart version for $CACHE_SERVER_CHART_REGISTRY/$CACHE_SERVER_CHART_REPO ..."
    CACHE_SERVER_CHART_VERSION="$(az acr repository show-tags \
        --name "$ACR_NAME_FOR_CHART" \
        --repository "$CACHE_SERVER_CHART_REPO" \
        --orderby time_desc --top 1 --output tsv 2>/dev/null || true)"
    if [[ -z "$CACHE_SERVER_CHART_VERSION" ]]; then
        echo "ERROR: failed to resolve latest chart version for" \
             "$CACHE_SERVER_CHART_REGISTRY/$CACHE_SERVER_CHART_REPO from ACR." >&2
        echo "       Confirm 'az login' + AcrPull on the registry, or set" >&2
        echo "       CACHE_SERVER_CHART_VERSION explicitly." >&2
        exit 1
    fi
    echo "Resolved latest chart version: $CACHE_SERVER_CHART_VERSION"
fi

CACHE_SERVER_IMAGE="${CACHE_SERVER_IMAGE_REGISTRY}/${CACHE_SERVER_IMAGE_REPO}:${CACHE_SERVER_IMAGE_TAG}"
CACHE_SERVER_CHART_REF="oci://${CACHE_SERVER_CHART_REGISTRY}/${CACHE_SERVER_CHART_REPO}"
CACHE_SERVER_PREREQ_CHART_REF="oci://${CACHE_SERVER_CHART_REGISTRY}/${CACHE_SERVER_PREREQ_CHART_REPO}"

echo "Using cache-server image: $CACHE_SERVER_IMAGE"
echo "Using prereq chart       : $CACHE_SERVER_PREREQ_CHART_REF (version $CACHE_SERVER_CHART_VERSION)"
echo "Using chart              : $CACHE_SERVER_CHART_REF (version $CACHE_SERVER_CHART_VERSION)"
echo "Namespace                : $NAMESPACE"
echo "Prereq release           : $PREREQ_RELEASE_NAME"
echo "Release                  : $RELEASE_NAME"
echo "Replicas                 : $CACHE_SERVER_REPLICAS"

# --- Pull + side-load the image -------------------------------------------

echo "Pulling image..."
docker pull "$CACHE_SERVER_IMAGE"

# Side-load the image into every kind node manually rather than using
# `kind load docker-image` or `kind load image-archive`.
#
# `kind load` invokes `ctr images import --all-platforms` inside the node,
# which requires the archive to contain blobs for EVERY platform referenced
# in the manifest list. When Docker is using the containerd image store (the
# default on newer Docker versions), `docker save` emits the full manifest
# list but only the blobs for the single platform it pulled -- so kind fails
# with:
#     ctr: content digest sha256:...: not found
# Driving `ctr images import` ourselves (without `--all-platforms`) makes
# containerd import only the platforms actually present in the archive,
# which is what we want.
IMAGE_TAR="$(mktemp --suffix=.tar)"
trap 'rm -f "$IMAGE_TAR"' EXIT

echo "Saving image to $IMAGE_TAR ..."
docker save "$CACHE_SERVER_IMAGE" -o "$IMAGE_TAR"

echo "Importing image into every node of kind cluster '$CLUSTER_NAME'..."
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
    echo "  -> $node"
    # Stream the archive on stdin instead of `docker cp`-ing it into the node
    # first: kind nodes have a tmpfs mount over /tmp that hides files written
    # via `docker cp` (which targets the underlying overlay layer), so the
    # copy silently succeeds but `ctr` inside the node sees no such file.
    docker exec -i "$node" ctr --namespace=k8s.io images import \
        --digests --snapshotter=overlayfs - < "$IMAGE_TAR"
done

# --- Deploy via Helm (OCI) -------------------------------------------------

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- ACR pull secret ------------------------------------------------------
#
# The kind nodes are separate containers with their own containerd runtime;
# they do NOT inherit the host's `az acr login` docker credentials. Any pod
# whose image is NOT the one we side-loaded above (e.g. cacheserver-scheduler
# pulled by the prereq chart) will fail to pull from ACR with a 401.
#
# We mint a short-lived AAD access token via `az acr login --expose-token`
# and drop it into a Kubernetes docker-registry secret in the target
# namespace. Special username 00000000-0000-0000-0000-000000000000 tells
# ACR that the password is an AAD access token.
#
# The secret is attached to the `default` ServiceAccount up front and to
# every ServiceAccount the charts create, right after each helm install
# (see `attach_pull_secret_to_all_sas` below).
ACR_PULL_SECRET_NAME="${ACR_PULL_SECRET_NAME:-acr-pull}"
ACR_NAME="${CACHE_SERVER_IMAGE_REGISTRY%%.*}"

if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: az CLI not found; cannot mint ACR pull secret." >&2
    echo "       Install az and run 'az login' before invoking this script." >&2
    exit 1
fi

echo "Fetching ACR access token for registry '$ACR_NAME' ..."
ACR_TOKEN="$(az acr login --name "$ACR_NAME" --expose-token --output tsv --query accessToken)"
if [[ -z "$ACR_TOKEN" ]]; then
    echo "ERROR: failed to obtain ACR access token for '$ACR_NAME'." >&2
    echo "       Run 'az login' and confirm you have AcrPull on the registry." >&2
    exit 1
fi

kubectl delete secret "$ACR_PULL_SECRET_NAME" -n "$NAMESPACE" --ignore-not-found
kubectl create secret docker-registry "$ACR_PULL_SECRET_NAME" \
    --docker-server="$CACHE_SERVER_IMAGE_REGISTRY" \
    --docker-username="00000000-0000-0000-0000-000000000000" \
    --docker-password="$ACR_TOKEN" \
    -n "$NAMESPACE"

# Patch the default SA so any pod that doesn't specify its own SA can pull.
kubectl patch serviceaccount default -n "$NAMESPACE" \
    -p "{\"imagePullSecrets\":[{\"name\":\"$ACR_PULL_SECRET_NAME\"}]}"

# Chart-created ServiceAccounts don't exist yet; helper below patches them
# right after each helm install so the pull secret takes effect before pods
# roll out.
attach_pull_secret_to_all_sas() {
    for sa in $(kubectl get serviceaccounts -n "$NAMESPACE" -o name); do
        kubectl patch "$sa" -n "$NAMESPACE" \
            -p "{\"imagePullSecrets\":[{\"name\":\"$ACR_PULL_SECRET_NAME\"}]}" \
            >/dev/null || true
    done
}

# Idempotency: drop any previous releases before installing.
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || true
helm uninstall "$PREREQ_RELEASE_NAME" -n "$NAMESPACE" || true

# Prereq chart first (CRDs / RBAC / cluster-scoped resources the main chart
# depends on). Pinned to the same version as the main chart.
#
# We install with --wait=false so we can patch chart-created SAs with the
# ACR pull secret before the pods finish pulling, then block on rollout.
# `--set (global.)imagePullSecrets[0].name` covers charts that read it
# directly; the SA-patch + pod-delete dance below covers charts that don't.
echo "Deploying cache-server prereq chart from $CACHE_SERVER_PREREQ_CHART_REF ..."
helm install "$PREREQ_RELEASE_NAME" "$CACHE_SERVER_PREREQ_CHART_REF" \
    --version "$CACHE_SERVER_CHART_VERSION" \
    -n "$NAMESPACE" \
    --set "global.imagePullSecrets[0].name=$ACR_PULL_SECRET_NAME" \
    --set "imagePullSecrets[0].name=$ACR_PULL_SECRET_NAME"

echo "Attaching ACR pull secret to prereq-chart ServiceAccounts ..."
attach_pull_secret_to_all_sas
# Delete any pods that were created before the SA patch took effect so they
# get recreated with the imagePullSecret inherited from the (now-patched) SA.
kubectl delete pods -n "$NAMESPACE" --all --wait=false >/dev/null || true

echo "Waiting for prereq chart rollout ..."
prereq_workloads=$(kubectl get deploy,statefulset,daemonset -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=$PREREQ_RELEASE_NAME" \
    -o name 2>/dev/null)
if [[ -n "$prereq_workloads" ]]; then
    # shellcheck disable=SC2086
    kubectl rollout status -n "$NAMESPACE" --timeout=10m $prereq_workloads || true
fi

echo "Deploying cache-server helm chart from $CACHE_SERVER_CHART_REF ..."
helm install "$RELEASE_NAME" "$CACHE_SERVER_CHART_REF" \
    --version "$CACHE_SERVER_CHART_VERSION" \
    -n "$NAMESPACE" \
    --set "global.imagePullSecrets[0].name=$ACR_PULL_SECRET_NAME" \
    --set "imagePullSecrets[0].name=$ACR_PULL_SECRET_NAME" \
    --set cacheServer.image.repository="${CACHE_SERVER_IMAGE%:*}" \
    --set cacheServer.image.tag="${CACHE_SERVER_IMAGE#*:}" \
    --set cacheServer.numServers="$CACHE_SERVER_REPLICAS" \
    --set cacheServer.scheduler.enabled=false

echo "Attaching ACR pull secret to cache-server-chart ServiceAccounts ..."
attach_pull_secret_to_all_sas
kubectl delete pods -n "$NAMESPACE" --all --wait=false >/dev/null || true

# --- Wait for pods to come up ---------------------------------------------

echo "Waiting for cacheserver pods to reach Running..."
while true; do
    ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app=cacheserver --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    total_pods=$(kubectl get pods -n "$NAMESPACE" -l app=cacheserver --no-headers 2>/dev/null | wc -l)
    if [[ "$ready_pods" -eq "$total_pods" && "$total_pods" -gt 0 ]]; then
        echo "All $total_pods cacheserver pod(s) are Running."
        break
    fi
    echo "  $ready_pods / $total_pods pods Running; sleeping 5s..."
    sleep 5
done

# --- Debug dump ------------------------------------------------------------

echo ""
echo "=========================================="
echo "CacheServer Deployment Status"
echo "=========================================="
echo ""

echo "StatefulSet:"
kubectl get statefulset -n "$NAMESPACE" || true
echo ""

echo "Services:"
kubectl get svc -n "$NAMESPACE" || true
echo ""

echo "Pods:"
kubectl get pods -n "$NAMESPACE" -o wide || true
echo ""

echo "Cacheserver pod DNS names (useful for debugging server-list):"
for pod in $(kubectl get pods -n "$NAMESPACE" -l app=cacheserver -o jsonpath='{.items[*].metadata.name}'); do
    echo "  $pod.cacheserver.$NAMESPACE.svc.cluster.local:$CACHE_SERVER_PORT"
done

echo ""
echo "Cache server deployed successfully!"
