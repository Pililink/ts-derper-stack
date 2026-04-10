# syntax=docker/dockerfile:1.7

ARG GO_IMAGE=golang:1.26.1-bookworm
ARG RUNTIME_IMAGE=debian:bookworm-slim
ARG TS_VERSION=v1.96.4

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder

ARG TARGETOS
ARG TARGETARCH
ARG TS_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --branch "${TS_VERSION}" --depth 1 https://github.com/tailscale/tailscale.git

WORKDIR /src/tailscale

ENV CGO_ENABLED=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/tailscaled ./cmd/tailscaled \
    && GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/tailscale ./cmd/tailscale \
    && GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/derper ./cmd/derper \
    && git rev-parse HEAD > /out/tailscale.revision \
    && printf '%s\n' "${TS_VERSION}" > /out/tailscale.version

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS verify-mock-builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY compose/verify-mock/go.mod compose/verify-mock/go.mod
COPY compose/verify-mock/main.go compose/verify-mock/main.go

ENV CGO_ENABLED=0

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /out/verify-mock ./main.go

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
COPY scripts/entrypoint.sh /opt/ts-derper/entrypoint.sh

RUN chmod +x /opt/ts-derper/entrypoint.sh

VOLUME ["/var/lib/derper", "/var/lib/tailscale", "/var/run/tailscale", "/var/cache/derper-certs", "/certs"]

EXPOSE 80/tcp 443/tcp 3478/udp

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/ts-derper/entrypoint.sh"]

FROM ${RUNTIME_IMAGE} AS verify-mock

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=verify-mock-builder /out/verify-mock /usr/local/bin/verify-mock

EXPOSE 8080/tcp

ENTRYPOINT ["/usr/local/bin/verify-mock"]
