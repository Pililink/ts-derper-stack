# syntax=docker/dockerfile:1.7@sha256:a57df69d0ea827fb7266491f2813635de6f17269be881f696fbfdf2d83dda33e

# golang:1.26.6-bookworm
ARG GO_IMAGE=golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36
# debian:bookworm-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
ARG TS_VERSION
ARG TS_COMMIT

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder

ARG TARGETOS
ARG TARGETARCH
ARG TS_VERSION
ARG TS_COMMIT

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# With no explicit build arguments, use the repository-tracked release and commit.
COPY tailscale-version.txt tailscale-commit.txt /tmp/
RUN set -eux; \
    ts_version="${TS_VERSION:-}"; \
    ts_commit="${TS_COMMIT:-}"; \
    if { [ -n "${ts_version}" ] && [ -z "${ts_commit}" ]; } || { [ -z "${ts_version}" ] && [ -n "${ts_commit}" ]; }; then \
        echo "TS_VERSION and TS_COMMIT must be supplied together" >&2; \
        exit 1; \
    fi; \
    if [ -z "${ts_version}" ]; then \
        ts_version="$(tr -d '\r\n' < /tmp/tailscale-version.txt)"; \
    fi; \
    if [ -z "${ts_commit}" ]; then \
        ts_commit="$(tr -d '\r\n' < /tmp/tailscale-commit.txt)"; \
    fi; \
    printf '%s\n' "${ts_version}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z][0-9A-Za-z.+-]*)?$' || { echo "Invalid Tailscale version: ${ts_version}" >&2; exit 1; }; \
    printf '%s\n' "${ts_commit}" | grep -Eq '^[0-9a-f]{40}$' || { echo "Invalid Tailscale commit: ${ts_commit}" >&2; exit 1; }; \
    git init /src/tailscale; \
    git -C /src/tailscale remote add origin https://github.com/tailscale/tailscale.git; \
    git -C /src/tailscale fetch --depth 1 origin "refs/tags/${ts_version}:refs/tags/${ts_version}"; \
    resolved_commit="$(git -C /src/tailscale rev-parse "refs/tags/${ts_version}^{commit}")"; \
    test "${resolved_commit}" = "${ts_commit}"; \
    git -C /src/tailscale checkout --detach "${ts_commit}"; \
    printf '%s\n' "${ts_version}" > /tmp/tailscale.version; \
    printf '%s\n' "${ts_commit}" > /tmp/tailscale.commit

WORKDIR /src/tailscale

ENV CGO_ENABLED=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/tailscaled ./cmd/tailscaled \
    && GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/tailscale ./cmd/tailscale \
    && GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/derper ./cmd/derper \
    && git rev-parse HEAD > /out/tailscale.revision \
    && cp /tmp/tailscale.version /out/tailscale.version \
    && cp /tmp/tailscale.commit /out/tailscale.commit

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS verify-mock-builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src/compose/verify-mock
COPY compose/verify-mock/go.mod ./go.mod
COPY compose/verify-mock/main.go ./main.go

ENV CGO_ENABLED=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/verify-mock .

FROM ${RUNTIME_IMAGE} AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 derper \
    && useradd --system --uid 10001 --gid 10001 --home /var/lib/derper --shell /usr/sbin/nologin derper \
    && mkdir -p /var/lib/derper /var/lib/tailscale /var/run/tailscale /var/cache/derper-certs /certs /opt/ts-derper \
    && chown -R derper:derper /var/lib/derper /var/lib/tailscale /var/run/tailscale /var/cache/derper-certs /certs /opt/ts-derper

COPY --from=builder /out/tailscaled /usr/local/bin/tailscaled
COPY --from=builder /out/tailscale /usr/local/bin/tailscale
COPY --from=builder /out/derper /usr/local/bin/derper
COPY --from=builder /out/tailscale.revision /usr/local/share/tailscale.revision
COPY --from=builder /out/tailscale.version /usr/local/share/tailscale.version
COPY --from=builder /out/tailscale.commit /usr/local/share/tailscale.commit
COPY scripts/entrypoint.sh /opt/ts-derper/entrypoint.sh

RUN sed -i 's/\r$//' /opt/ts-derper/entrypoint.sh \
    && chmod +x /opt/ts-derper/entrypoint.sh

VOLUME ["/var/lib/derper", "/var/lib/tailscale", "/var/run/tailscale", "/var/cache/derper-certs", "/certs"]

EXPOSE 80/tcp 443/tcp 3478/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/ts-derper/entrypoint.sh"]
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 CMD ["/opt/ts-derper/entrypoint.sh", "healthcheck"]

FROM ${RUNTIME_IMAGE} AS verify-mock

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=verify-mock-builder /out/verify-mock /usr/local/bin/verify-mock

EXPOSE 8080/tcp

ENTRYPOINT ["/usr/local/bin/verify-mock"]
