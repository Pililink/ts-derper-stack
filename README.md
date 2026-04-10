# ts-derper-stack

用于统一构建 `tailscaled`、`tailscale`、`derper` 的自定义 DERP 中继镜像仓库，内置本地 Compose 联调和 GitHub Actions 多架构发布。

## 功能概览

- 基于同一 Tailscale 源码版本编译 `tailscaled`、`tailscale`、`derper`，满足 `--verify-clients` 的同 revision 约束。
- 单镜像同时支持：
  - `verify-clients`，依赖同容器内嵌 `tailscaled`，或同 Pod/同宿主机挂载现成 socket。
  - `verify-client-url`，可直接对接 Headscale 的 `/verify`。
- 支持标准端口部署和自定义端口部署。
- 提供 Docker Compose 本地测试环境。
- 提供 GitHub Actions 自动构建并推送 `linux/amd64`、`linux/arm64` 多架构镜像。

## 目录结构

```text
.
├── .github/workflows/docker.yml
├── .github/workflows/sync-tailscale-release.yml
├── compose/verify-mock
├── docker-compose.yml
├── Dockerfile
├── scripts/entrypoint.sh
└── tailscale-version.txt
```

## 快速开始

### 0. 构建镜像

当前 `Dockerfile` 依赖 BuildKit 特性：

- `# syntax=docker/dockerfile:1.7`
- `RUN --mount=type=cache,...`

本地建议直接使用：

```bash
docker buildx build --load --target runtime -t ts-derper-stack:test .
```

如果仍然使用 `docker build`，请确保本机 Docker 已启用 BuildKit。

### 1. 本地自定义端口启动

默认 Compose 使用 `3340/tcp + 3478/udp`，避免本机直接占用 `80/443`。

```bash
docker compose up --build -d derper
curl -i http://127.0.0.1:3340/generate_204
```

### 2. 本地测试 `verify-client-url`

仓库自带一个验证 mock 服务，便于联调 `DERPAdmitClientRequest` 流程。

```bash
docker compose --profile verify-url up --build -d
```

常用环境变量示例：

```bash
DERP_AUTH_MODE=verify-client-url
DERP_VERIFY_CLIENT_URL=http://verify-mock:8080/verify
DERP_VERIFY_CLIENT_URL_FAIL_OPEN=true
```

### 3. 启用 `verify-clients`

`verify-clients` 需要 `derper` 与 `tailscaled` 使用同一源码 revision，本仓库镜像已保证这一点。启动时有两种方式：

1. 内嵌 `tailscaled`

```bash
docker run --rm \
  -e DERP_AUTH_MODE=verify-clients \
  -e TAILSCALED_RUN=true \
  -e TAILSCALE_AUTH_KEY=tskey-xxxxx \
  -p 443:443/tcp \
  -p 80:80/tcp \
  -p 3478:3478/udp \
  ghcr.io/your-org/ts-derper-stack:latest
```

2. 复用同 Pod 或同宿主机已有 `tailscaled` socket

```bash
docker run --rm \
  -e DERP_AUTH_MODE=verify-clients \
  -e TAILSCALED_RUN=false \
  -e TAILSCALED_SOCKET_PATH=/var/run/tailscale/tailscaled.sock \
  -v /var/run/tailscale:/var/run/tailscale \
  ghcr.io/your-org/ts-derper-stack:latest
```

## 环境变量

### DERP 相关

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DERP_ADDR` | `:443` | `derper -a` 监听地址。非 `443` 端口时默认走纯 HTTP。 |
| `DERP_HTTP_PORT` | `80` | HTTP 端口，设为 `-1` 可关闭。 |
| `DERP_STUN_PORT` | `3478` | STUN UDP 端口。 |
| `DERP_AUTH_MODE` | `none` | `none`、`verify-clients`、`verify-client-url`。 |
| `DERP_CONFIG_PATH` | `/var/lib/derper/derper.key` | DERP 私钥文件路径。 |
| `DERP_CERT_MODE` | `letsencrypt` | `derper -certmode`。本地自定义端口场景通常不会触发 TLS。 |
| `DERP_CERT_DIR` | `/var/cache/derper-certs` | Let’s Encrypt 缓存目录。 |
| `DERP_HOSTNAME` | 空 | 对外域名。生产上使用 `:443` 时建议必填。 |
| `DERP_HOME` | 空 | 主页行为，映射到 `derper -home`。 |
| `DERP_VERIFY_CLIENT_URL` | 空 | `verify-client-url` 模式下的 admission controller 地址。 |
| `DERP_VERIFY_CLIENT_URL_FAIL_OPEN` | `true` | URL 验证服务不可达时是否 fail-open。 |
| `DERP_MESH_PSK_FILE` | 空 | 透传 `-mesh-psk-file`。 |
| `DERP_MESH_WITH` | 空 | 透传 `-mesh-with`。 |
| `DERP_BOOTSTRAP_DNS_NAMES` | 空 | 透传 `-bootstrap-dns-names`。 |
| `DERP_EXTRA_ARGS` | 空 | 补充透传给 `derper` 的额外参数。 |

### Tailscale 相关

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TAILSCALED_RUN` | `auto` | `auto` 时，只有 `verify-clients` 会自动启动内嵌 `tailscaled`。 |
| `TAILSCALED_SOCKET_PATH` | `/var/run/tailscale/tailscaled.sock` | LocalAPI socket 路径。 |
| `TAILSCALED_STATE_DIR` | `/var/lib/tailscale` | `tailscaled` 状态目录。 |
| `TAILSCALED_TUN` | `userspace-networking` | 默认避免容器额外依赖 TUN/NET_ADMIN。 |
| `TAILSCALED_WAIT_TIMEOUT` | `60` | 等待 socket/LocalAPI 就绪的超时时间。 |
| `TAILSCALED_EXTRA_ARGS` | 空 | 额外传给 `tailscaled`。 |
| `TAILSCALE_AUTH_KEY` | 空 | 内嵌 `tailscaled` 时用于自动 `tailscale up`。 |
| `TAILSCALE_LOGIN_SERVER` | 空 | 自定义 control plane，例如 Headscale。 |
| `TAILSCALE_HOSTNAME` | 空 | `tailscale up --hostname`。 |
| `TAILSCALE_UP_EXTRA_ARGS` | 空 | 追加到 `tailscale up`。 |

## 标准端口部署

公网部署推荐直接绑定标准端口，并使用域名证书：

```bash
docker run -d \
  --name derper \
  -e DERP_ADDR=:443 \
  -e DERP_HTTP_PORT=80 \
  -e DERP_STUN_PORT=3478 \
  -e DERP_HOSTNAME=derp.example.com \
  -e DERP_AUTH_MODE=verify-client-url \
  -e DERP_VERIFY_CLIENT_URL=https://headscale.example.com/verify \
  -p 80:80/tcp \
  -p 443:443/tcp \
  -p 3478:3478/udp \
  -v derper-data:/var/lib/derper \
  -v derper-certs:/var/cache/derper-certs \
  ghcr.io/your-org/ts-derper-stack:latest
```

## Compose 说明

### 本地纯 DERP

```bash
docker compose up --build -d derper
```

### 本地 URL 验证联调

```bash
DERP_AUTH_MODE=verify-client-url docker compose --profile verify-url up --build -d
```

### 本地嵌入 `tailscaled`

```bash
DERP_AUTH_MODE=verify-clients \
TAILSCALED_RUN=true \
TAILSCALE_AUTH_KEY=tskey-xxxxx \
docker compose up --build -d derper
```

## GitHub Actions 发布

工作流文件位于 `.github/workflows/docker.yml`，默认行为：

- PR：仅构建，不推送。
- push 到 `main` 或 `v*` tag：构建并推送到 `ghcr.io/<owner>/<repo>`。
- 如果配置了 Docker Hub 仓库名，也会同步推送到 Docker Hub。
- 使用 `docker/build-push-action` 输出 `linux/amd64` 与 `linux/arm64`。
- 构建使用仓库根目录的 `tailscale-version.txt` 作为上游 Tailscale 版本来源。

另外新增 `.github/workflows/sync-tailscale-release.yml`：

- 每 30 分钟检查一次 `tailscale/tailscale` 的最新 release。
- 如果发现新版 release，则直接调用构建流程构建并发布新镜像。
- 只有构建成功后，才会自动更新 `tailscale-version.txt` 并推送到 `main`。

手动切换要构建的上游版本时，直接修改 `tailscale-version.txt` 即可。

需要配置的仓库 Secrets / Variables：

| 类型 | 名称 | 用途 |
| --- | --- | --- |
| Secret | `DOCKERHUB_USERNAME` | Docker Hub 用户名。 |
| Secret | `DOCKERHUB_TOKEN` | Docker Hub Access Token，建议不要用账号密码。 |
| Variable | `DOCKERHUB_IMAGE` | Docker Hub 镜像名，例如 `pililink/ts-derper-stack`。留空则只推 GHCR。 |

## 常见问题

### `verify-clients` 模式下客户端全部被拒绝

优先检查：

1. `derper` 与 `tailscaled` 是否来自同一 Tailscale revision。
2. `tailscaled` 是否已成功 `tailscale up` 并加入目标 tailnet。
3. DERP 客户端是否在该 `tailscaled` 的 ACL 可见范围内。

### `verify-client-url` 模式连接超时

优先检查：

1. `DERP_VERIFY_CLIENT_URL` 是否可从容器内访问。
2. `DERP_VERIFY_CLIENT_URL_FAIL_OPEN` 是否符合预期。
3. Headscale 是否暴露了 `/verify`。

### 生产上为什么建议标准端口

`derper` 官方建议开放 `80/tcp`、`443/tcp`、`3478/udp`。其中 `443/tcp` 用于 DERP/TLS，`80/tcp` 常用于 ACME HTTP-01，`3478/udp` 用于 STUN。

## 参考

- Tailscale DERP README: https://github.com/tailscale/tailscale/tree/main/cmd/derper
- Tailscale 最新 release（当前默认版本参考）: https://github.com/tailscale/tailscale/releases/tag/v1.96.4
- Headscale `/verify` 处理逻辑: https://github.com/juanfont/headscale/blob/main/hscontrol/handlers.go
