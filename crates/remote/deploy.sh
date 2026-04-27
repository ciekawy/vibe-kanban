#!/bin/sh
# Smart deploy: skip Docker build if the image for the current commit already exists.
# Set as the Dokploy deploy command for the vk-remote compose application.
#
# In Dokploy: set this as the "Deploy Command" for the compose application:
#   sh crates/remote/deploy.sh

set -e

COMMIT=$(git rev-parse --short HEAD)
IMAGE="vk-remote:${COMMIT}"

# Remove stale containers and Compose state to avoid "No such container" errors
# when Dokploy has already removed old containers outside Compose's control.
docker compose --env-file .env.remote down --remove-orphans 2>/dev/null || true

if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
  echo "Image ${IMAGE} already exists, skipping build"
  DOCKER_IMAGE_TAG="${COMMIT}" docker compose --env-file .env.remote up -d --force-recreate --remove-orphans
else
  echo "Building image ${IMAGE}"
  DOCKER_IMAGE_TAG="${COMMIT}" docker compose --env-file .env.remote up -d --build --force-recreate --remove-orphans
fi
