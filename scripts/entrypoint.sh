#!/usr/bin/env bash

set -Eeuo pipefail

log() {
  printf '[entrypoint] %s\n' "$*"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "missing required environment variable: ${name}"
    return 1
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

tailscaled_local_api_available() {
  /usr/local/bin/tailscale --socket="${TAILSCALED_SOCKET_PATH}" status --json >/dev/null 2>&1
}

tailscaled_backend_running() {
  /usr/local/bin/tailscale --socket="${TAILSCALED_SOCKET_PATH}" status --json 2>/dev/null \
    | grep -Eq '"BackendState"[[:space:]]*:[[:space:]]*"Running"'
}

wait_for_tailscaled_api() {
  local end=$((SECONDS + TAILSCALED_WAIT_TIMEOUT))

  while (( SECONDS < end )); do
    if tailscaled_local_api_available; then
      return 0
    fi
    sleep 1
  done

  return 1
}

wait_for_tailscaled_running() {
  local end=$((SECONDS + TAILSCALED_WAIT_TIMEOUT))

  while (( SECONDS < end )); do
    if tailscaled_backend_running; then
      return 0
    fi
    sleep 1
  done

  return 1
}

derp_listen_port() {
  local address="$1"
  local port="${address##*:}"

  if [[ "${address}" != *:* || -z "${port}" || ! "${port}" =~ ^[0-9]+$ ]]; then
    printf '[entrypoint] DERP_ADDR must end with a numeric port: %s\n' "${address}" >&2
    return 1
  fi

  printf '%s\n' "${port}"
}

derp_uses_tls() {
  local port
  port="$(derp_listen_port "${DERP_ADDR}")" || return 1
  [[ "${port}" == "443" || "${DERP_CERT_MODE}" == "manual" ]]
}

run_healthcheck() {
  local health_url="${DERP_HEALTHCHECK_URL}"

  if [[ -z "${health_url}" ]]; then
    local port
    local scheme="http"
    port="$(derp_listen_port "${DERP_ADDR}")" || return 1
    if derp_uses_tls; then
      scheme="https"
    fi
    health_url="${scheme}://127.0.0.1:${port}/generate_204"
  fi

  curl --fail --silent --show-error --insecure --max-time 5 "${health_url}" >/dev/null

  if [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
    tailscaled_backend_running
  fi
}

shutdown_children() {
  local exit_code="${1:-0}"
  local pid

  for pid in "${DERPER_PID:-}" "${TAILSCALED_MONITOR_PID:-}" "${TAILSCALED_PID:-}"; do
    if [[ -n "${pid}" ]]; then
      kill -TERM "${pid}" >/dev/null 2>&1 || true
    fi
  done

  for pid in "${DERPER_PID:-}" "${TAILSCALED_MONITOR_PID:-}" "${TAILSCALED_PID:-}"; do
    if [[ -n "${pid}" ]]; then
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done

  exit "${exit_code}"
}

fail() {
  log "$*"
  shutdown_children 1
}

start_embedded_tailscaled() {
  if ! mkdir -p "$(dirname "${TAILSCALED_SOCKET_PATH}")" "${TAILSCALED_STATE_DIR}"; then
    fail "failed to create tailscaled state directories"
  fi

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
    fail "tailscaled socket was not created in time: ${TAILSCALED_SOCKET_PATH}"
  fi

  if ! wait_for_tailscaled_api; then
    fail "tailscaled LocalAPI was not ready within ${TAILSCALED_WAIT_TIMEOUT}s"
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
    if ! /usr/local/bin/tailscale "${tailscale_up_args[@]}"; then
      fail "tailscale up failed"
    fi
  elif [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
    log "verify-clients is enabled but TAILSCALE_AUTH_KEY is empty; relying on existing tailscaled state"
  fi

  if [[ "${DERP_AUTH_MODE}" == "verify-clients" ]] && ! wait_for_tailscaled_running; then
    fail "tailscaled backend did not reach Running within ${TAILSCALED_WAIT_TIMEOUT}s"
  fi
}

wait_for_external_tailscaled() {
  if ! mkdir -p "$(dirname "${TAILSCALED_SOCKET_PATH}")"; then
    fail "failed to create tailscaled socket directory"
  fi
  log "waiting for external tailscaled socket: ${TAILSCALED_SOCKET_PATH}"

  if ! wait_for_socket "${TAILSCALED_SOCKET_PATH}" "${TAILSCALED_WAIT_TIMEOUT}"; then
    fail "external tailscaled socket was not found: ${TAILSCALED_SOCKET_PATH}"
  fi

  if ! wait_for_tailscaled_running; then
    fail "external tailscaled backend did not reach Running within ${TAILSCALED_WAIT_TIMEOUT}s"
  fi
}

monitor_tailscaled_backend() {
  while kill -0 "${DERPER_PID}" >/dev/null 2>&1; do
    sleep 5
    if ! tailscaled_backend_running; then
      log "tailscaled backend is no longer Running; stopping derper"
      # The monitor is a background subshell. Signal the parent so its trap
      # terminates the container with a non-zero status and restart policy applies.
      kill -TERM "${DERPER_PID}" >/dev/null 2>&1 || true
      kill -TERM "${ENTRYPOINT_PID}" >/dev/null 2>&1 || true
      return 0
    fi
  done
}

wait_for_children() {
  local exit_code=0

  if [[ -n "${TAILSCALED_PID:-}" ]]; then
    local exited_pid=""
    if wait -n -p exited_pid "${DERPER_PID}" "${TAILSCALED_PID}"; then
      exit_code=0
    else
      exit_code=$?
    fi

    if [[ "${exited_pid}" == "${TAILSCALED_PID}" ]]; then
      log "embedded tailscaled exited; stopping derper"
      if [[ "${exit_code}" -eq 0 ]]; then
        exit_code=1
      fi
    fi
  elif wait "${DERPER_PID}"; then
    exit_code=0
  else
    exit_code=$?
  fi

  shutdown_children "${exit_code}"
}

ENTRYPOINT_PID=$$
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

DERP_PORT_WAS_SET="false"
if [[ -n "${DERP_PORT+x}" ]]; then
  DERP_PORT_WAS_SET="true"
fi
DERP_PORT="${DERP_PORT:-443}"
DERP_ADDR="${DERP_ADDR:-:${DERP_PORT}}"
DERP_HTTP_PORT="${DERP_HTTP_PORT:-80}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_CONFIG_PATH="${DERP_CONFIG_PATH:-/var/lib/derper/derper.key}"
DERP_CERT_MODE="${DERP_CERT_MODE:-letsencrypt}"
DERP_CERT_DIR="${DERP_CERT_DIR:-/var/cache/derper-certs}"
DERP_HOSTNAME="${DERP_HOSTNAME:-}"
DERP_HOME="${DERP_HOME:-}"
DERP_VERIFY_CLIENT_URL="${DERP_VERIFY_CLIENT_URL:-}"
DERP_VERIFY_CLIENT_URL_FAIL_OPEN="${DERP_VERIFY_CLIENT_URL_FAIL_OPEN:-false}"
DERP_MESH_PSK_FILE="${DERP_MESH_PSK_FILE:-}"
DERP_MESH_WITH="${DERP_MESH_WITH:-}"
DERP_BOOTSTRAP_DNS_NAMES="${DERP_BOOTSTRAP_DNS_NAMES:-}"
DERP_EXTRA_ARGS="${DERP_EXTRA_ARGS:-}"
DERP_HEALTHCHECK_URL="${DERP_HEALTHCHECK_URL:-}"

case "${DERP_AUTH_MODE}" in
  none|verify-clients|verify-client-url)
    ;;
  *)
    fail "unsupported DERP_AUTH_MODE: ${DERP_AUTH_MODE}"
    ;;
esac

case "${TAILSCALED_RUN}" in
  auto)
    if [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
      TAILSCALED_RUN="true"
    else
      TAILSCALED_RUN="false"
    fi
    ;;
  true|false)
    ;;
  *)
    fail "TAILSCALED_RUN must be auto, true, or false"
    ;;
esac

if [[ ! "${TAILSCALED_WAIT_TIMEOUT}" =~ ^[1-9][0-9]*$ ]]; then
  fail "TAILSCALED_WAIT_TIMEOUT must be a positive integer"
fi

case "${DERP_VERIFY_CLIENT_URL_FAIL_OPEN}" in
  true|false)
    ;;
  *)
    fail "DERP_VERIFY_CLIENT_URL_FAIL_OPEN must be true or false"
    ;;
esac

if ! DERP_ADDR_PORT="$(derp_listen_port "${DERP_ADDR}")"; then
  fail "invalid DERP_ADDR: ${DERP_ADDR}"
fi

if [[ "${DERP_PORT_WAS_SET}" == "true" && "${DERP_ADDR_PORT}" != "${DERP_PORT}" ]]; then
  fail "DERP_PORT (${DERP_PORT}) must match the port in DERP_ADDR (${DERP_ADDR})"
fi

if derp_uses_tls; then
  if ! require_env "DERP_HOSTNAME"; then
    fail "DERP_HOSTNAME is required when DERP serves TLS"
  fi

  case "${DERP_CERT_MODE}" in
    letsencrypt|gcp)
      if [[ "${DERP_HTTP_PORT}" == "-1" ]]; then
        fail "DERP_HTTP_PORT must be enabled for ACME certificate mode"
      fi
      ;;
  esac
fi

if [[ "${1:-}" == "healthcheck" ]]; then
  run_healthcheck
  exit $?
fi

if [[ "${TAILSCALED_RUN}" == "true" ]]; then
  start_embedded_tailscaled
elif [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
  wait_for_external_tailscaled
fi

if ! mkdir -p "$(dirname "${DERP_CONFIG_PATH}")" "${DERP_CERT_DIR}" /var/lib/derper; then
  fail "failed to create DERP state directories"
fi

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
    if ! require_env "DERP_VERIFY_CLIENT_URL"; then
      fail "DERP_VERIFY_CLIENT_URL is required for verify-client-url mode"
    fi
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

if [[ "${DERP_AUTH_MODE}" == "verify-clients" ]]; then
  monitor_tailscaled_backend &
  TAILSCALED_MONITOR_PID=$!
fi

wait_for_children
