#!/bin/sh
# Smart deploy: skip Docker build if the image for the current commit already exists.
# Set as the Dokploy deploy command for the vk-remote compose application.

set -e

COMMIT=$(git rev-parse --short HEAD)
IMAGE="vk-remote:${COMMIT}"

if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
  echo "Image ${IMAGE} already exists, skipping build"
  DOCKER_IMAGE_TAG="${COMMIT}" docker compose --env-file .env.remote up -d
else
  echo "Building image ${IMAGE}"
  DOCKER_IMAGE_TAG="${COMMIT}" docker compose --env-file .env.remote up -d --build
fi
