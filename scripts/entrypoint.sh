#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '[entrypoint] %s\n' "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "missing required environment variable: ${name}"
    exit 1
  fi
}

append_flag() {
  local flag_name="$1"
  local value="${2:-}"
  if [[ -n "${value}" ]]; then
    DERPER_ARGS+=("${flag_name}" "${value}")
  fi
}

wait_for_socket() {
  local socket_path="$1"
  local wait_seconds="$2"
  local end=$((SECONDS + wait_seconds))

  while (( SECONDS < end )); do
    if [[ -S "${socket_path}" ]]; then
      return 0
    fi
    sleep 1
  done

  return 1
}

start_embedded_tailscaled() {
  mkdir -p "$(dirname "${TAILSCALED_SOCKET_PATH}")" "${TAILSCALED_STATE_DIR}"

  if [[ -S "${TAILSCALED_SOCKET_PATH}" ]]; then
    rm -f "${TAILSCALED_SOCKET_PATH}"
  fi

  local state_file="${TAILSCALED_STATE_DIR}/tailscaled.state"
  local -a tailscaled_args=(
    "--socket=${TAILSCALED_SOCKET_PATH}"
    "--statedir=${TAILSCALED_STATE_DIR}"
    "--state=${state_file}"
    "--tun=${TAILSCALED_TUN}"
  )

  if [[ -n "${TAILSCALED_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    tailscaled_args+=(${TAILSCALED_EXTRA_ARGS})
  fi

  log "starting embedded tailscaled"
  /usr/local/bin/tailscaled "${tailscaled_args[@]}" &
  TAILSCALED_PID=$!

  if ! wait_for_socket "${TAILSCALED_SOCKET_PATH}" "${TAILSCALED_WAIT_TIMEOUT}"; then
    log "tailscaled socket was not created in time: ${TAILSCALED_SOCKET_PATH}"
    exit 1
  fi

  local end=$((SECONDS + TAILSCALED_WAIT_TIMEOUT))
  while (( SECONDS < end )); do
    if /usr/local/bin/tailscale --socket="${TAILSCALED_SOCKET_PATH}" status --json >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if (( SECONDS >= end )); then
    log "tailscaled LocalAPI was not ready within ${TAILSCALED_WAIT_TIMEOUT}s"
    exit 1
  fi

  if [[ -n "${TAILSCALE_AUTH_KEY}" ]]; then
    local -a tailscale_up_args=(
      "--socket=${TAILSCALED_SOCKET_PATH}"
      "up"
      "--auth-key=${TAILSCALE_AUTH_KEY}"
    )

    if [[ -n "${TAILSCALE_LOGIN_SERVER}" ]]; then
      tailscale_up_args+=("--login-server=${TAILSCALE_LOGIN_SERVER}")
    fi
    if [[ -n "${TAILSCALE_HOSTNAME}" ]]; then
      tailscale_up_args+=("--hostname=${TAILSCALE_HOSTNAME}")
    fi
    if [[ -n "${TAILSCALE_UP_EXTRA_ARGS}" ]]; then
      # shellcheck disable=SC2206
      tailscale_up_args+=(${TAILSCALE_UP_EXTRA_ARGS})
    fi

    log "running tailscale up"
    /usr/local/bin/tailscale "${tailscale_up_args[@]}"
  elif [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
    log "verify-clients is enabled but TAILSCALE_AUTH_KEY is empty; relying on existing tailscaled state"
  fi
}

wait_for_external_tailscaled() {
  mkdir -p "$(dirname "${TAILSCALED_SOCKET_PATH}")"
  log "waiting for external tailscaled socket: ${TAILSCALED_SOCKET_PATH}"

  if ! wait_for_socket "${TAILSCALED_SOCKET_PATH}" "${TAILSCALED_WAIT_TIMEOUT}"; then
    log "external tailscaled socket was not found: ${TAILSCALED_SOCKET_PATH}"
    exit 1
  fi
}

shutdown_children() {
  local exit_code="${1:-0}"

  if [[ -n "${DERPER_PID:-}" ]]; then
    kill "${DERPER_PID}" >/dev/null 2>&1 || true
    wait "${DERPER_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TAILSCALED_PID:-}" ]]; then
    kill "${TAILSCALED_PID}" >/dev/null 2>&1 || true
    wait "${TAILSCALED_PID}" >/dev/null 2>&1 || true
  fi

  exit "${exit_code}"
}

trap 'shutdown_children 143' SIGINT SIGTERM

DERP_AUTH_MODE="${DERP_AUTH_MODE:-none}"
TAILSCALED_RUN="${TAILSCALED_RUN:-auto}"
TAILSCALED_TUN="${TAILSCALED_TUN:-userspace-networking}"
TAILSCALED_SOCKET_PATH="${TAILSCALED_SOCKET_PATH:-/var/run/tailscale/tailscaled.sock}"
TAILSCALED_STATE_DIR="${TAILSCALED_STATE_DIR:-/var/lib/tailscale}"
TAILSCALED_WAIT_TIMEOUT="${TAILSCALED_WAIT_TIMEOUT:-60}"
TAILSCALED_EXTRA_ARGS="${TAILSCALED_EXTRA_ARGS:-}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_LOGIN_SERVER="${TAILSCALE_LOGIN_SERVER:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
TAILSCALE_UP_EXTRA_ARGS="${TAILSCALE_UP_EXTRA_ARGS:-}"

DERP_ADDR="${DERP_ADDR:-:443}"
DERP_HTTP_PORT="${DERP_HTTP_PORT:-80}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_CONFIG_PATH="${DERP_CONFIG_PATH:-/var/lib/derper/derper.key}"
DERP_CERT_MODE="${DERP_CERT_MODE:-letsencrypt}"
DERP_CERT_DIR="${DERP_CERT_DIR:-/var/cache/derper-certs}"
DERP_HOSTNAME="${DERP_HOSTNAME:-}"
DERP_HOME="${DERP_HOME:-}"
DERP_VERIFY_CLIENT_URL="${DERP_VERIFY_CLIENT_URL:-}"
DERP_VERIFY_CLIENT_URL_FAIL_OPEN="${DERP_VERIFY_CLIENT_URL_FAIL_OPEN:-true}"
DERP_MESH_PSK_FILE="${DERP_MESH_PSK_FILE:-}"
DERP_MESH_WITH="${DERP_MESH_WITH:-}"
DERP_BOOTSTRAP_DNS_NAMES="${DERP_BOOTSTRAP_DNS_NAMES:-}"
DERP_EXTRA_ARGS="${DERP_EXTRA_ARGS:-}"

case "${DERP_AUTH_MODE}" in
  none|verify-clients|verify-client-url)
    ;;
  *)
    log "unsupported DERP_AUTH_MODE: ${DERP_AUTH_MODE}"
    exit 1
    ;;
esac

if [[ "${TAILSCALED_RUN}" == "auto" ]]; then
  if [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
    TAILSCALED_RUN="true"
  else
    TAILSCALED_RUN="false"
  fi
fi

if [[ "${TAILSCALED_RUN}" == "true" ]]; then
  start_embedded_tailscaled
elif [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
  wait_for_external_tailscaled
fi

mkdir -p "$(dirname "${DERP_CONFIG_PATH}")" "${DERP_CERT_DIR}" /var/lib/derper

DERPER_ARGS=(
  "-a" "${DERP_ADDR}"
  "-http-port" "${DERP_HTTP_PORT}"
  "-stun-port" "${DERP_STUN_PORT}"
  "-c" "${DERP_CONFIG_PATH}"
  "-certmode" "${DERP_CERT_MODE}"
  "-certdir" "${DERP_CERT_DIR}"
)

append_flag "-hostname" "${DERP_HOSTNAME}"
append_flag "-home" "${DERP_HOME}"
append_flag "-mesh-psk-file" "${DERP_MESH_PSK_FILE}"
append_flag "-mesh-with" "${DERP_MESH_WITH}"
append_flag "-bootstrap-dns-names" "${DERP_BOOTSTRAP_DNS_NAMES}"

case "${DERP_AUTH_MODE}" in
  verify-clients)
    DERPER_ARGS+=("--verify-clients" "--socket" "${TAILSCALED_SOCKET_PATH}")
    ;;
  verify-client-url)
    require_env "DERP_VERIFY_CLIENT_URL"
    DERPER_ARGS+=("--verify-client-url" "${DERP_VERIFY_CLIENT_URL}" "--verify-client-url-fail-open=${DERP_VERIFY_CLIENT_URL_FAIL_OPEN}")
    ;;
esac

if [[ -n "${DERP_EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  DERPER_ARGS+=(${DERP_EXTRA_ARGS})
fi

if (( "$#" > 0 )); then
  DERPER_ARGS+=("$@")
fi

log "starting derper with auth mode ${DERP_AUTH_MODE}"
/usr/local/bin/derper "${DERPER_ARGS[@]}" &
DERPER_PID=$!

DERPER_EXIT_CODE=0
wait "${DERPER_PID}" || DERPER_EXIT_CODE=$?

shutdown_children "${DERPER_EXIT_CODE}"
