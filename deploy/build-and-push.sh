#!/usr/bin/env bash
# Builds and publishes monokek-spring, pms-modulith and the backup image to
# Docker Hub. Run from the repo root: ./deploy/build-and-push.sh [tag]
#
# Requires `docker login` for an account with push access to
# DOCKERHUB_NAMESPACE (images are private — see deploy/README.md), and
# DOCKERHUB_NAMESPACE set in .env or the environment.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

: "${DOCKERHUB_NAMESPACE:?Set DOCKERHUB_NAMESPACE in .env or the environment}"
TAG="${1:-${IMAGE_TAG:-latest}}"

build_and_push() {
    local name="$1" context="$2"
    local image="docker.io/${DOCKERHUB_NAMESPACE}/${name}:${TAG}"
    echo "==> Building ${image}"
    docker build -t "${image}" "${context}"
    echo "==> Pushing ${image}"
    docker push "${image}"
}

build_and_push monokek-spring ./monokek-spring
build_and_push pms-modulith ./pms/pms-modulith
build_and_push monokek-backup ./deploy/backup

echo "Done. Published under docker.io/${DOCKERHUB_NAMESPACE} at tag ${TAG}"
