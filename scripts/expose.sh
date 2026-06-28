#!/usr/bin/env bash
# Build the project's Docker service on the runner, publish it to the public internet via the NetBird reverse proxy (netbird expose).
set -euo pipefail

PORT="${PORT:?PORT is required}"
PROTOCOL="${PROTOCOL:-http}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker-compose.yml}"
APP_ENV="${APP_ENV:-}"
EXPOSE_DURATION="${EXPOSE_DURATION:-5m}"
CUSTOM_DOMAIN="${CUSTOM_DOMAIN:-}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
PASSWORD="${PASSWORD:-}"
PIN="${PIN:-}"
USER_GROUPS="${USER_GROUPS:-}"
ALLOW_SSH="${ALLOW_SSH:-false}"

if ! [[ "${PORT}" =~ ^[0-9]+$ ]]; then
  echo "error: PORT must be numeric (got '${PORT}')" >&2
  exit 1
fi

mask_url() {
  local url="$1" scheme="" rest
  case "${url}" in
    *://*) scheme="${url%%://*}://"; rest="${url#*://}" ;;
    *)     rest="${url}" ;;
  esac
  if [ "${#rest}" -le 6 ]; then
    printf '%s***' "${scheme}"          # too short to partially reveal safely
  else
    printf '%s%s***%s' "${scheme}" "${rest:0:3}" "${rest: -3}" # The space in ${rest: -3} is mandatory 
  fi
}

# Convert a duration like 30s / 10m / 1h / 5d (or a bare number = seconds) to seconds.
to_seconds() {
  local input="$1" num unit
  if [[ "${input}" =~ ^([0-9]+)([smhd]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-s}"
    case "${unit}" in
      s) echo "$(( num ))" ;;
      m) echo "$(( num * 60 ))" ;;
      h) echo "$(( num * 3600 ))" ;;
      d) echo "$(( num * 86400 ))" ;;
    esac
  else
    echo "error: EXPOSE_DURATION must be a number optionally suffixed with s/m/h/d (got '${input}')" >&2
    exit 1
  fi
}

EXPOSE_SECONDS="$(to_seconds "${EXPOSE_DURATION}")"

case "${PROTOCOL}" in
  http|https|tcp|udp|tls) ;;
  *) echo "error: PROTOCOL must be one of http|https|tcp|udp|tls (got '${PROTOCOL}')" >&2; exit 1 ;;
esac


SUDO=()
if [ "$(id -u)" -ne 0 ]; then
  SUDO=(sudo)
fi

# --- the runner must already be on the mesh (netbird-connect ran) ---
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

# --- turn APP_ENV (KEY=VALUE per line, # comments) into a .env file ---
format_env() {
  local dest="$1" line count=0
  if [ -e "${dest}" ]; then
    echo "warning: overwriting existing '${dest}' with app-env values." >&2
  fi
  ( umask 077; : > "${dest}" )   # created 0600, no chmod race
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"                       # strip CR from CRLF input
    line="${line#"${line%%[![:space:]]*}"}"    # left-trim whitespace
    [ -z "${line}" ] && continue               # skip blank lines
    case "${line}" in '#'*) continue ;; esac   # skip comments
    if ! printf '%s' "${line}" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
      echo "warning: skipping an app-env line without a valid KEY= prefix" >&2
      continue
    fi
    printf '%s\n' "${line}" >> "${dest}"
    count=$(( count + 1 ))
  done <<< "${APP_ENV}"
}

# Set the global ENV_ARGS to (--env-file <path>) from APP_ENV, or leave it empty when APP_ENV is unset.
ENV_ARGS=()
ENV_FILE=""
prepare_env_file() {
  ENV_ARGS=()
  [ -n "${APP_ENV}" ] || return 0
  local dest="${1:-}"
  [ -n "${dest}" ] || dest="$(mktemp /tmp/app-env.XXXXXX)"
  ENV_FILE="${dest}"
  format_env "${dest}"
  ENV_ARGS=(--env-file "${dest}")
}

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
  
  prepare_env_file "$(dirname "${DOCKER_COMPOSE}")/.env"

  "${dc[@]}" "${ENV_ARGS[@]}" -f "${DOCKER_COMPOSE}" up -d --build
}

start_with_dockerfile() {
  if [ ! -f "${DOCKERFILE}" ]; then
    echo "error: '${DOCKERFILE}' is missing." >&2
    exit 1
  fi
  local image="netbird-expose"
  docker build -f "${DOCKERFILE}" -t "${image}" .
  docker rm -f netbird-expose >/dev/null 2>&1 || true
  
  prepare_env_file

  docker run -d --name netbird-expose "${ENV_ARGS[@]}" -p "${PORT}:${PORT}" "${image}"
}

if [ -f "${DOCKER_COMPOSE}" ]; then
  start_with_docker_compose
else
  start_with_dockerfile
fi

# --- optionally enable the NetBird SSH server on the runner ---
if [ "${ALLOW_SSH}" = "true" ]; then
  "${SUDO[@]}" netbird down || true
  "${SUDO[@]}" netbird up --allow-server-ssh --enable-ssh-local-port-forwarding \
    --enable-ssh-remote-port-forwarding --enable-ssh-sftp --enable-ssh-root \
    --network-monitor=true --disable-ssh-auth
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
    "${SUDO[@]}" kill -INT "${EXPOSE_PID}" 2>/dev/null || true
    wait "${EXPOSE_PID}" 2>/dev/null || true
  fi
  if [ -f "${DOCKER_COMPOSE}" ]; then
    docker compose -f "${DOCKER_COMPOSE}" down >/dev/null 2>&1 || true
  else
    docker rm -f netbird-expose >/dev/null 2>&1 || true
  fi
  if [ -n "${ENV_FILE}" ]; then
    rm -f "${ENV_FILE}" 2>/dev/null || true
  fi
  if [ -n "${EXPOSE_LOG:-}" ]; then
    rm -f "${EXPOSE_LOG}" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

EXPOSE_LOG="$(mktemp /tmp/netbird-expose.XXXXXX.log)"
"${SUDO[@]}" netbird expose "${expose_args[@]}" "${PORT}" >"${EXPOSE_LOG}" 2>&1 &
EXPOSE_PID=$!

# Wait for the URL line, while watching for an early exit.
URL=""
deadline=$(( SECONDS + 60 ))
while (( SECONDS < deadline )); do
  if ! kill -0 "${EXPOSE_PID}" 2>/dev/null; then
    echo "error: 'netbird expose' exited before exposing (permission denied, peer expose disabled, or proxy unavailable)." >&2
    cat "${EXPOSE_LOG}" >&2
    wait "${EXPOSE_PID}"
    exit 1
  fi
  URL="$(sed -n 's/^[[:space:]]*URL:[[:space:]]*//p' "${EXPOSE_LOG}" | head -n1)"
  [ -n "${URL}" ] && break
  sleep 1
done

if [ -z "${URL}" ]; then
  echo "warning: exposed, but timed out reading the URL from netbird output." >&2
else
  NAME="$(sed -n 's/^[[:space:]]*Name:[[:space:]]*//p'     "${EXPOSE_LOG}" | head -n1)"
  DOMAIN="$(sed -n 's/^[[:space:]]*Domain:[[:space:]]*//p' "${EXPOSE_LOG}" | head -n1)"
  # Belt-and-suspenders: hide the real values from any later log line too.
  [ -n "${NAME}" ]   && echo "::add-mask::${NAME}"
  echo "::add-mask::${URL}"
  [ -n "${DOMAIN}" ] && echo "::add-mask::${DOMAIN}"
  echo "Service exposed successfully!"
  echo "  URL: $(mask_url "${URL}")"
fi

sleep "${EXPOSE_SECONDS}"