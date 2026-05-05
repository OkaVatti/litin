# syntax = docker/dockerfile:1

# ─────────────────────── Stage 1: Build Litin ───────────────────────
FROM docker.io/crystallang/crystal:1.20.1-alpine AS builder

WORKDIR /litin
COPY shard.yml shard.lock ./
RUN shards install

COPY src/ src/
COPY spec/ spec/
COPY .git/ .git/

# Create target directories
RUN mkdir -p /usr/local/sbin /sbin /build

# Build all binaries
RUN crystal build src/litind.cr    -o /usr/local/sbin/litind    --release
RUN crystal build src/litinctl.cr  -o /usr/local/bin/litinctl  --release
RUN crystal build src/litin_init.cr -o /sbin/litin_init         --release

# ─────────────────────── Stage 2: Test image ───────────────────────
FROM docker.io/alpine:3.23

# Install test dependencies
RUN apk add --no-cache \
    bash \
    crystal \
    shards

# Copy Litin binaries from builder
COPY --from=builder /usr/local/sbin/litind    /usr/local/sbin/litind
COPY --from=builder /usr/local/bin/litinctl   /usr/local/bin/litinctl
COPY --from=builder /sbin/litin_init          /sbin/litin_init

# Set up filesystem layout for Litin
RUN mkdir -p /litin/build && ln -s /usr/local/sbin/litind /litin/build/litind

RUN mkdir -p /etc/litin/services \
    /etc/litin/targets \
    /etc/litin/sockets \
    /etc/litin/timers \
    /etc/litin/masks \
    /run/litin/notify \
    /var/log/litin && \
    touch /etc/litin/litin.conf

# Pre‑create a minimal default target
RUN echo 'name="default"\ndescription="Default boot target"' > /etc/litin/targets/default.target

# Symlink so the integration test can find litind at ../../build/litind
RUN mkdir -p /build && ln -s /usr/local/sbin/litind /build/litind

# Environment variables to put everything under writable paths
ENV LITIND_BIN=/usr/local/sbin/litind \
    LITIND_SERVICES_DIR=/etc/litin/services \
    LITIND_SOCKETS_DIR=/etc/litin/sockets \
    LITIND_TIMERS_DIR=/etc/litin/timers \
    LITIND_TARGETS_DIR=/etc/litin/targets \
    LITIND_SOCKET_PATH=/run/litin/litind.sock \
    LITIN_LOG_DIR=/var/log/litin \
    LITIN_RUN_DIR=/run/litin \
    LITIND_CGROUP_ENABLED=false

# Copy project source for tests
WORKDIR /litin
COPY . .

# Install Crystal dependencies (shard.lock already present)
RUN shards install

# Default command: run the whole test suite
CMD ["sh", "-c", "crystal spec ./spec --order random"]