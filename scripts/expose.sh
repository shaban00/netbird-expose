#!/usr/bin/env bash
#
# Build the project's Docker service on the runner, publish it to the public internet via the NetBird reverse proxy (netbird expose).
set -euo pipefail

PORT="${PORT:?PORT is required}"
PROTOCOL="${PROTOCOL:-http}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker-compose.yml}"
EXPOSE_DURATION="${EXPOSE_DURATION:-300}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
PASSWORD="${PASSWORD:-}"
PIN="${PIN:-}"
USER_GROUPS="${USER_GROUPS:-}"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
  echo "error: PORT must be numeric (got '${PORT}')" >&2
  exit 1
fi
if ! [[ "${EXPOSE_DURATION}" =~ ^[0-9]+$ ]]; then
  echo "error: EXPOSE_DURATION must be numeric (got '${EXPOSE_DURATION}')" >&2
  exit 1
fi

case "${PROTOCOL}" in
  http|https|tcp|udp|tls) ;;
  *) echo "error: PROTOCOL must be one of http|https|tcp|udp|tls (got '${PROTOCOL}')" >&2; exit 1 ;;
esac

# netbird needs root; docker on GitHub runners does not.
SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  SUDO=(sudo)
fi

# --- the runner must already be on the mesh (netbird-connect ran) -------------
if ! "${SUDO[@]}" netbird status >/dev/null 2>&1; then
  echo "error: netbird service is not running on the runner." >&2
  echo "       Start the daemon (e.g. 'netbird service start') and run shaban00/netbird-connect first." >&2
  exit 1
fi

if ! "${SUDO[@]}" netbird status 2>/dev/null | grep -qiE 'Management.*Connected'; then
  echo "error: runner is not connected to NetBird." >&2
  echo "       Run shaban00/netbird-connect before this action." >&2
  exit 1
fi

start_with_docker_compose() {
  local dc=()
  if docker compose version >/dev/null 2>&1; then
    dc=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    dc=(docker-compose)
  else
    echo "error: no docker compose available on the runner." >&2
    exit 1
  fi
  "${dc[@]}" -f "${DOCKER_COMPOSE}" up -d --build
}

start_with_dockerfile() {
  if [ ! -f "${DOCKERFILE}" ]; then
    echo "error: '${DOCKERFILE}' is missing." >&2
    exit 1
  fi
  local image="netbird-expose"
  docker build -f "${DOCKERFILE}" -t "${image}" .
  docker rm -f netbird-expose >/dev/null 2>&1 || true
  docker run -d --name netbird-expose -p "${PORT}:${PORT}" "${image}"
}

if [ -f "${DOCKER_COMPOSE}" ]; then
  start_with_docker_compose
else
  start_with_dockerfile
fi

expose_args=(--protocol "${PROTOCOL}")
if [ -n "${CUSTOM_DOMAIN}" ]; then expose_args+=(--with-custom-domain "${CUSTOM_DOMAIN}"); fi
if [ -n "${EXTERNAL_PORT}" ]; then expose_args+=(--with-external-port "${EXTERNAL_PORT}"); fi
if [ -n "${NAME_PREFIX}" ];   then expose_args+=(--with-name-prefix "${NAME_PREFIX}"); fi
if [ -n "${PASSWORD}" ];      then expose_args+=(--with-password "${PASSWORD}"); fi
if [ -n "${PIN}" ];           then expose_args+=(--with-pin "${PIN}"); fi
if [ -n "${USER_GROUPS}" ];   then expose_args+=(--with-user-groups "${USER_GROUPS}"); fi


EXPOSE_PID=""

cleanup() {
  if [ -n "${EXPOSE_PID}" ]; then
    echo "Stopping netbird expose (pid ${EXPOSE_PID})..."
    "${SUDO[@]}" kill -INT "${EXPOSE_PID}" 2>/dev/null || true
    wait "${EXPOSE_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

"${SUDO[@]}" netbird expose "${expose_args[@]}" "${PORT}" &
EXPOSE_PID=$!

sleep "${EXPOSE_DURATION}"