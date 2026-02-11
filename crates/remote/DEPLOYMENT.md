# Remote Deployment on Dokploy

## Problem: DNS Resolution Between Services

When Dokploy deploys a docker-compose stack, it overrides the network of the
"main" service (the one with exposed ports / Traefik routing) to use
`dokploy-network` — an overlay network used for Traefik ingress. Other services
remain on the compose-default bridge network. Because the services end up on
different networks, they can't resolve each other by hostname.

### Current Fix (Hardcoded)

All services explicitly join `dokploy-network` plus the `default` compose
network, and `dokploy-network` is declared as `external: true` at the bottom of
`docker-compose.yml`.

This works but couples the compose file to Dokploy. Running
`docker compose up` without Dokploy will fail unless you create the network
manually first (`docker network create dokploy-network`).

### Recommended Decoupled Approach

Keep `docker-compose.yml` free of any Dokploy-specific references. Use a
**compose override file** that layers the networking on top.

**docker-compose.yml** — clean, platform-agnostic:

```yaml
services:
  remote-db:
    # ... no networks key
  electric:
    # ... no networks key
  remote-server:
    # ... no networks key
```

**docker-compose.dokploy.yml** — Dokploy-specific overlay:

```yaml
services:
  remote-db:
    networks: [dokploy-network, default]
  electric:
    networks: [dokploy-network, default]
  remote-server:
    networks: [dokploy-network, default]

networks:
  dokploy-network:
    external: true
```

How to use:

- **Standalone / local**: `docker compose up` — just works, no external network
  needed.
- **Dokploy**: Set the compose command/path in Dokploy to merge both files:
  `docker compose -f docker-compose.yml -f docker-compose.dokploy.yml up`
  Alternatively, if Dokploy auto-loads `docker-compose.override.yml`, rename the
  overlay file to that and place it next to the main compose file.

## Problem: Rust Build Not Cached

The Dockerfile uses `--mount=type=cache` for the cargo registry and build
target, which should provide fast incremental builds. However, the cache is
**invalidated on every build** because of how the `COPY` layer works:

```dockerfile
COPY crates crates          # <-- this copies ALL crates
COPY shared shared
COPY assets assets
```

Any change to **any file** in any crate (not just `remote`) busts the Docker
layer cache, which forces cargo to re-evaluate and recompile from scratch. Since
the `--mount=type=cache,target=/app/target` cache mount persists across builds,
the cargo incremental compilation cache should survive — but in practice this
often doesn't help enough because:

1. **Docker BuildKit cache mounts are node-local.** Dokploy may run builds on
   different swarm nodes, or the cache volume may get pruned between deploys.
2. **The entire `crates/` directory is copied.** Even unrelated changes (e.g., a
   comment in `crates/server/`) invalidate the COPY layer and force a full
   rebuild inside the RUN step that follows.

### Recommendations to Improve Build Caching

**Option A — Dependency pre-build (skeleton trick):**

Split the Dockerfile into two stages: first copy only `Cargo.toml` / `Cargo.lock`
files with empty `lib.rs` stubs to pre-build dependencies, then copy actual
sources for the final build. This way dependency compilation is cached unless
`Cargo.toml` or `Cargo.lock` change.

```dockerfile
# 1. Copy only manifests + create stub sources
COPY Cargo.toml Cargo.lock ./
COPY crates/remote/Cargo.toml crates/remote/Cargo.toml
COPY crates/db/Cargo.toml crates/db/Cargo.toml
# ... other crate Cargo.tomls that remote depends on
RUN mkdir -p crates/remote/src && echo "" > crates/remote/src/lib.rs
# ... same for other crates
RUN cargo build --release --manifest-path crates/remote/Cargo.toml

# 2. Copy real sources and rebuild (only app code recompiles)
COPY crates crates
COPY shared shared
COPY assets assets
RUN cargo build --release --manifest-path crates/remote/Cargo.toml
```

**Option B — Use `cargo-chef` (recommended):**

[cargo-chef](https://github.com/LukeMathWalker/cargo-chef) automates the
skeleton trick more reliably:

```dockerfile
FROM rust:1.93-slim-bookworm AS chef
RUN cargo install cargo-chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
RUN cargo build --release --manifest-path crates/remote/Cargo.toml
```

**Option C — Pre-built image (current workaround):**

Build the `vk-remote` image locally or in CI where caching is reliable, push to
a registry, and reference `image: vk-remote` in docker-compose.yml (what's
currently being done). This sidesteps Dokploy's build entirely.
