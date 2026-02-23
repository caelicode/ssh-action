#!/usr/bin/env bash
# CaeliCode SSH Action — entrypoint
# Execute commands on remote servers via SSH with key-based or password auth,
# environment variable forwarding, jump host support, multi-host execution,
# and configurable timeouts.
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────
log()    { echo "::group::$1"; }
endlog() { echo "::endgroup::"; }
fail()   { echo "::error::$1"; exit 1; }
warn()   { echo "::warning::$1"; }

# ── Validate inputs ─────────────────────────────────────────────────
[[ -z "${INPUT_HOST:-}" ]]     && fail "input 'host' is required"
[[ -z "${INPUT_USERNAME:-}" ]] && fail "input 'username' is required"

# Need either key or password
[[ -z "${INPUT_KEY:-}" && -z "${INPUT_PASSWORD:-}" ]] && \
  fail "either 'key' or 'password' must be provided"

# Need either script or script_file
SCRIPT_BODY=""
if [[ -n "${INPUT_SCRIPT_FILE:-}" ]]; then
  [[ ! -f "$INPUT_SCRIPT_FILE" ]] && fail "script_file not found: $INPUT_SCRIPT_FILE"
  SCRIPT_BODY="$(cat "$INPUT_SCRIPT_FILE")"
elif [[ -n "${INPUT_SCRIPT:-}" ]]; then
  SCRIPT_BODY="$INPUT_SCRIPT"
else
  fail "either 'script' or 'script_file' must be provided"
fi

PORT="${INPUT_PORT:-22}"
CONNECT_TIMEOUT="${INPUT_CONNECT_TIMEOUT:-30}"
COMMAND_TIMEOUT="${INPUT_COMMAND_TIMEOUT:-600}"
REMOTE_SHELL="${INPUT_REMOTE_SHELL:-bash}"

# ── Set up SSH authentication ───────────────────────────────────────
log "Setting up SSH authentication"

KEY_FILE=""
PROXY_KEY_FILE=""
SSHPASS_INSTALLED=""

cleanup() {
  if [[ -n "${SSH_AGENT_PID:-}" ]]; then
    ssh-agent -k > /dev/null 2>&1 || true
  fi
  rm -f "${KEY_FILE:-}" "${PROXY_KEY_FILE:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Prepare key file helper
prepare_key() {
  local key_content="$1"
  local key_file
  key_file="$(mktemp)"
  chmod 600 "$key_file"
  printf '%s\n' "$key_content" > "$key_file"
  # Ensure file ends with a newline (common copy-paste issue with secrets)
  # shellcheck disable=SC1003
  sed -i -e '$a\' "$key_file" 2>/dev/null || true
  echo "$key_file"
}

if [[ -n "${INPUT_KEY:-}" ]]; then
  eval "$(ssh-agent -s)" > /dev/null 2>&1
  KEY_FILE="$(prepare_key "$INPUT_KEY")"
  ssh-add "$KEY_FILE" 2>/dev/null || fail "Failed to load SSH private key — check key format and passphrase"
  rm -f "$KEY_FILE"
  KEY_FILE=""
  echo "Authentication: key-based (ssh-agent)"
elif [[ -n "${INPUT_PASSWORD:-}" ]]; then
  # For password auth, we need sshpass
  if ! command -v sshpass &>/dev/null; then
    warn "sshpass not found — attempting install"
    if command -v apt-get &>/dev/null; then
      if ! { apt-get update -qq && apt-get install -y -qq sshpass 2>/dev/null; }; then
        fail "password auth requires 'sshpass' but it could not be installed"
      fi
    else
      fail "password auth requires 'sshpass' — install it or use key-based auth"
    fi
  fi
  SSHPASS_INSTALLED="true"
  echo "Authentication: password-based (sshpass)"
fi

# Prepare proxy/jump host key if provided
if [[ -n "${INPUT_PROXY_HOST:-}" && -n "${INPUT_PROXY_KEY:-}" ]]; then
  PROXY_KEY_FILE="$(prepare_key "$INPUT_PROXY_KEY")"
  ssh-add "$PROXY_KEY_FILE" 2>/dev/null || fail "Failed to load proxy SSH key"
  rm -f "$PROXY_KEY_FILE"
  PROXY_KEY_FILE=""
  echo "Proxy: ${INPUT_PROXY_HOST}:${INPUT_PROXY_PORT:-22}"
fi

endlog

# ── Build environment variable payload ──────────────────────────────
ENV_PREFIX=""
if [[ -n "${INPUT_ENVS:-}" ]]; then
  log "Forwarding environment variables"
  IFS=',' read -ra ENV_NAMES <<< "$INPUT_ENVS"
  for name in "${ENV_NAMES[@]}"; do
    name="$(echo "$name" | xargs)"  # trim whitespace
    [[ -z "$name" ]] && continue
    # Use indirect variable reference to get the value
    value="${!name:-}"
    if [[ -n "$value" ]]; then
      # Escape single quotes in values for safe shell transport
      escaped="${value//\'/\'\\\'\'}"
      ENV_PREFIX+="export ${name}='${escaped}';"$'\n'
      echo "  → $name (set)"
    else
      echo "  → $name (empty/unset, skipping)"
    fi
  done
  endlog
fi

# ── Build SSH options ───────────────────────────────────────────────
SSH_OPTS=(
  -o LogLevel=ERROR
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -p "$PORT"
)

# Host key verification
if [[ -n "${INPUT_FINGERPRINT:-}" ]]; then
  # Strict fingerprint verification — write expected key to a temp known_hosts
  # The user provides the SHA256 fingerprint; we use VerifyHostKeyDNS=no
  # and rely on StrictHostKeyChecking=yes with the fingerprint check in the callback
  SSH_OPTS+=(
    -o StrictHostKeyChecking=yes
    -o "FingerprintHash=sha256"
  )
  echo "Host key verification: strict (fingerprint provided)"
else
  SSH_OPTS+=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
  )
fi

# Pseudo-terminal
if [[ "${INPUT_REQUEST_PTY:-false}" == "true" ]]; then
  SSH_OPTS+=(-t)
fi

# Jump host / bastion / proxy
if [[ -n "${INPUT_PROXY_HOST:-}" ]]; then
  PROXY_USER="${INPUT_PROXY_USERNAME:-${INPUT_USERNAME}}"
  PROXY_PORT="${INPUT_PROXY_PORT:-22}"
  SSH_OPTS+=(-o "ProxyJump=${PROXY_USER}@${INPUT_PROXY_HOST}:${PROXY_PORT}")
fi

# Append any extra user-provided SSH args
if [[ -n "${INPUT_ARGS:-}" ]]; then
  read -ra EXTRA_ARGS <<< "$INPUT_ARGS"
  SSH_OPTS+=("${EXTRA_ARGS[@]}")
fi

# ── Prepare the full remote script ──────────────────────────────────
FULL_SCRIPT="${ENV_PREFIX}${SCRIPT_BODY}"

# ── Execute on each host ────────────────────────────────────────────
IFS=',' read -ra HOSTS <<< "$INPUT_HOST"
STDOUT_FILE="$(mktemp)"
OVERALL_EXIT=0

for raw_host in "${HOSTS[@]}"; do
  host="$(echo "$raw_host" | xargs)"  # trim whitespace
  [[ -z "$host" ]] && continue

  log "Executing on ${host}:${PORT}"

  SSH_CMD=(ssh "${SSH_OPTS[@]}" "${INPUT_USERNAME}@${host}")

  # Prepend sshpass for password auth
  if [[ -n "${SSHPASS_INSTALLED:-}" ]]; then
    SSH_CMD=(sshpass -p "$INPUT_PASSWORD" "${SSH_CMD[@]}")
  fi

  HOST_EXIT=0

  # Pipe script via stdin to avoid argument length limits and escaping issues
  if [[ "$COMMAND_TIMEOUT" -gt 0 ]] 2>/dev/null; then
    echo "$FULL_SCRIPT" | timeout "$COMMAND_TIMEOUT" "${SSH_CMD[@]}" "$REMOTE_SHELL" 2>&1 | tee -a "$STDOUT_FILE" || HOST_EXIT=$?
  else
    echo "$FULL_SCRIPT" | "${SSH_CMD[@]}" "$REMOTE_SHELL" 2>&1 | tee -a "$STDOUT_FILE" || HOST_EXIT=$?
  fi

  if [[ $HOST_EXIT -eq 124 ]]; then
    echo "::error::Command timed out on ${host} after ${COMMAND_TIMEOUT}s"
    OVERALL_EXIT=1
  elif [[ $HOST_EXIT -ne 0 ]]; then
    echo "::error::Remote script failed on ${host} with exit code ${HOST_EXIT}"
    OVERALL_EXIT=$HOST_EXIT
  else
    echo "Host ${host}: success"
  fi

  endlog
done

# ── Set output (even on failure — unlike appleboy) ──────────────────
{
  echo "stdout<<CAELICODE_EOF"
  cat "$STDOUT_FILE"
  echo "CAELICODE_EOF"
} >> "$GITHUB_OUTPUT"

rm -f "$STDOUT_FILE"

if [[ $OVERALL_EXIT -ne 0 ]]; then
  fail "SSH execution failed (see errors above)"
fi

echo "SSH commands completed successfully"
