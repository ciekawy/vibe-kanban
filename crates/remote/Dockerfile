# syntax=docker/dockerfile:1.6

ARG APP_NAME=remote
ARG FEATURES=""

FROM node:20-alpine AS fe-builder
WORKDIR /repo

RUN corepack enable

COPY pnpm-lock.yaml pnpm-workspace.yaml package.json ./
COPY frontend/package.json frontend/package.json
COPY remote-frontend/package.json remote-frontend/package.json

RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --filter ./remote-frontend --frozen-lockfile

COPY remote-frontend/ remote-frontend/

RUN pnpm -C remote-frontend build

FROM rust:1.93-slim-bookworm AS builder
ARG APP_NAME
ARG FEATURES
ARG POSTHOG_API_KEY=""
ARG POSTHOG_API_ENDPOINT=""

ENV CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse
ENV POSTHOG_API_KEY=${POSTHOG_API_KEY}
ENV POSTHOG_API_ENDPOINT=${POSTHOG_API_ENDPOINT}

# Install build dependencies, plus git and openssh-client for private repo access
RUN apt-get update \
  && apt-get install -y --no-install-recommends pkg-config libssl-dev ca-certificates git openssh-client \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY rust-toolchain.toml ./
COPY crates/remote/Cargo.toml crates/remote/Cargo.lock crates/remote/
COPY crates/remote/.sqlx crates/remote/.sqlx
COPY crates/remote/migrations crates/remote/migrations
COPY crates/api-types crates/api-types
COPY crates/utils crates/utils
COPY shared shared
COPY assets assets

# Copy only the remote crate source last so unrelated changes don't bust cache
COPY crates/remote/src crates/remote/src

RUN mkdir -p /app/bin

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/app/crates/remote/target \
    cargo build --locked --release --manifest-path crates/remote/Cargo.toml ${FEATURES:+--features ${FEATURES}} \
 && cp crates/remote/target/release/${APP_NAME} /app/bin/${APP_NAME}

FROM debian:bookworm-slim AS runtime
ARG APP_NAME

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libssl3 wget git \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --create-home --uid 10001 appuser

WORKDIR /srv

COPY --from=builder /app/bin/${APP_NAME} /usr/local/bin/${APP_NAME}
COPY --from=fe-builder /repo/remote-frontend/dist /srv/static

USER appuser

ENV SERVER_LISTEN_ADDR=0.0.0.0:8081 \
    RUST_LOG=info

EXPOSE 8081

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget","--spider","-q","http://127.0.0.1:8081/health"]

ENTRYPOINT ["/usr/local/bin/remote"]
