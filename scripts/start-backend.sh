#!/usr/bin/env bash
set -Eeuo pipefail

# Chekinana RunPod backend bootstrap.
# Intended RunPod start command:
#   bash /workspace/chekinana/scripts/start-backend.sh
#
# The pod filesystem may be freshly migrated. Keep the repo under /workspace,
# recreate /root/.ssh from environment on every start, sync GitHub first, then
# start the Flask backend.

log() {
  printf '[chekinana:start] %s\n' "$*"
}

die() {
  printf '[chekinana:start:ERROR] %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  printf '[chekinana:start:ERROR] command failed at line %s with exit code %s\n' "$line_no" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

APP_DIR="${CHEKINANA_APP_DIR:-/workspace/chekinana}"
BACKEND_DIR="$APP_DIR/backend"
STATE_DIR="${CHEKINANA_STATE_DIR:-/workspace/.chekinana}"
ENV_DIR="${CHEKINANA_ENV_DIR:-$STATE_DIR/venv}"
REPO_URL="${CHEKINANA_REPO_URL:-ssh://git@ssh.github.com:443/czhovo/chekinana.git}"
REPO_BRANCH="${CHEKINANA_REPO_BRANCH:-main}"
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
THREADS="${THREADS:-6}"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu130}"
SSH_KEY_PATH="${CHEKINANA_SSH_KEY_PATH:-/root/.ssh/chekinana_github}"

export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=utf-8
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$STATE_DIR/pip-cache}"
export HF_HOME="${HF_HOME:-$STATE_DIR/huggingface}"
export TORCH_HOME="${TORCH_HOME:-$STATE_DIR/torch}"
export MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-$STATE_DIR/modelscope}"

mkdir -p /workspace "$STATE_DIR" "$PIP_CACHE_DIR" "$HF_HOME" "$TORCH_HOME" "$MODELSCOPE_CACHE"

ensure_command() {
  local cmd="$1"
  local pkg="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log "$cmd not found; installing $pkg with apt-get"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends "$pkg"
  fi

  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd. Install $pkg in the RunPod template."
}

write_ssh_key() {
  local key_b64_value="${CHEKINANA_GITHUB_SSH_KEY_B64:-${GITHUB_SSH_PRIVATE_KEY_B64:-}}"
  if [ -n "$key_b64_value" ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    printf '%s' "$key_b64_value" | tr -d '\r\n ' | base64 -d > "$SSH_KEY_PATH"
    chmod 600 "$SSH_KEY_PATH"
    return 0
  fi

  local key_value="${CHEKINANA_GITHUB_SSH_KEY:-${GITHUB_SSH_PRIVATE_KEY:-}}"
  if [ -z "$key_value" ]; then
    return 1
  fi

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  printf '%s\n' "$key_value" | sed 's/\r$//' > "$SSH_KEY_PATH"
  chmod 600 "$SSH_KEY_PATH"
  return 0
}

prepare_ssh() {
  ensure_command ssh openssh-client
  ensure_command ssh-keyscan openssh-client

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  if write_ssh_key; then
    log "GitHub SSH key written to $SSH_KEY_PATH"
  elif [ -f "$SSH_KEY_PATH" ]; then
    chmod 600 "$SSH_KEY_PATH"
    log "Using existing SSH key at $SSH_KEY_PATH"
  elif [ -f /root/.ssh/id_ed25519 ]; then
    SSH_KEY_PATH="/root/.ssh/id_ed25519"
    chmod 600 "$SSH_KEY_PATH"
    log "Using existing default SSH key at $SSH_KEY_PATH"
  elif [ -f /root/.ssh/id_rsa ]; then
    SSH_KEY_PATH="/root/.ssh/id_rsa"
    chmod 600 "$SSH_KEY_PATH"
    log "Using existing default SSH key at $SSH_KEY_PATH"
  else
    die "No GitHub SSH key found. Set CHEKINANA_GITHUB_SSH_KEY_B64, CHEKINANA_GITHUB_SSH_KEY, GITHUB_SSH_PRIVATE_KEY_B64, or GITHUB_SSH_PRIVATE_KEY in the RunPod environment."
  fi

  cat > /root/.ssh/config <<EOF
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new

Host ssh.github.com
  Port 443
  User git
  IdentityFile $SSH_KEY_PATH
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 /root/.ssh/config

  if [ -n "${GITHUB_KNOWN_HOSTS:-}" ]; then
    printf '%s\n' "$GITHUB_KNOWN_HOSTS" > /root/.ssh/known_hosts
  else
    ssh-keyscan -p 443 ssh.github.com > /root/.ssh/known_hosts 2>/dev/null || true
    ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null || true
  fi
  chmod 600 /root/.ssh/known_hosts || true

  export GIT_SSH_COMMAND="ssh -F /root/.ssh/config -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
}

sync_repo() {
  ensure_command git git
  prepare_ssh

  log "Syncing GitHub repo: $REPO_URL branch: $REPO_BRANCH"
  if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" remote set-url origin "$REPO_URL"
    git -C "$APP_DIR" fetch --prune origin "+refs/heads/$REPO_BRANCH:refs/remotes/origin/$REPO_BRANCH" || die "GitHub sync failed during fetch. Check SSH key, network, repo URL, and branch."
    git -C "$APP_DIR" checkout -B "$REPO_BRANCH" "origin/$REPO_BRANCH" || die "GitHub sync failed during checkout."
    git -C "$APP_DIR" reset --hard "origin/$REPO_BRANCH" || die "GitHub sync failed during reset."
  else
    if [ -e "$APP_DIR" ] && [ "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]; then
      local backup_dir="${APP_DIR}.non-git.$(date +%Y%m%d-%H%M%S)"
      log "$APP_DIR exists but is not a git repo; moving it to $backup_dir"
      mv "$APP_DIR" "$backup_dir"
    fi

    git clone --branch "$REPO_BRANCH" --single-branch "$REPO_URL" "$APP_DIR" || die "GitHub sync failed during clone. Check SSH key, network, repo URL, and branch."
  fi

  if [ -f "$APP_DIR/.gitmodules" ]; then
    git -C "$APP_DIR" submodule update --init --recursive || die "GitHub sync failed during submodule update."
  fi

  log "GitHub sync complete: $(git -C "$APP_DIR" rev-parse --short HEAD) $(git -C "$APP_DIR" log -1 --pretty=%s)"
}

pick_python() {
  if [ -n "${CHEKINANA_PYTHON:-}" ]; then
    PYTHON_BIN="$CHEKINANA_PYTHON"
  elif [ -x "$ENV_DIR/bin/python" ]; then
    PYTHON_BIN="$ENV_DIR/bin/python"
  else
    ensure_command python3 python3
    log "Creating Python environment at $ENV_DIR"
    if ! python3 -m venv "$ENV_DIR"; then
      if command -v apt-get >/dev/null 2>&1; then
        log "python3 venv creation failed; installing python3-venv and retrying"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends python3-venv
        python3 -m venv "$ENV_DIR" || die "Failed to create venv after installing python3-venv. Set CHEKINANA_PYTHON to a usable Python."
      else
        die "Failed to create venv. Install python3-venv or set CHEKINANA_PYTHON."
      fi
    fi
    PYTHON_BIN="$ENV_DIR/bin/python"
  fi

  [ -x "$PYTHON_BIN" ] || die "Python executable is not available: $PYTHON_BIN"
}

install_dependencies() {
  [ -f "$BACKEND_DIR/requirements.txt" ] || die "Missing backend requirements: $BACKEND_DIR/requirements.txt"

  pick_python
  log "Python: $("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"

  local stamp_file="$STATE_DIR/requirements.sha256"
  local new_stamp
  new_stamp="$(sha256sum "$BACKEND_DIR/requirements.txt" | awk '{print $1}'):$PYTORCH_INDEX_URL"

  local needs_install=0
  if [ ! -f "$stamp_file" ] || [ "$(cat "$stamp_file")" != "$new_stamp" ]; then
    needs_install=1
  elif ! "$PYTHON_BIN" - <<'PY' >/dev/null 2>&1
import cv2
import flask
import numpy
import PIL
import scipy
import torch
import transformers
import modelscope
import quadrilateral_fitter
PY
  then
    needs_install=1
  fi

  if [ "$needs_install" -eq 1 ]; then
    log "Installing/updating backend dependencies"
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install torch torchvision --index-url "$PYTORCH_INDEX_URL"
    "$PYTHON_BIN" -m pip install -r "$BACKEND_DIR/requirements.txt"
    printf '%s\n' "$new_stamp" > "$stamp_file"
  else
    log "Python dependencies already match current requirements"
  fi

  "$PYTHON_BIN" - <<'PY'
import torch
print(f"[chekinana:start] torch={torch.__version__} cuda={torch.cuda.is_available()}", flush=True)
if torch.cuda.is_available():
    print(f"[chekinana:start] gpu={torch.cuda.get_device_name(0)}", flush=True)
PY
}

start_backend() {
  [ -d "$BACKEND_DIR" ] || die "Backend directory not found after sync: $BACKEND_DIR"

  export HOST="$HOST"
  export PORT="$PORT"
  export THREADS="$THREADS"
  if [ -z "${CHEKINANA_ACCESS_TOKEN:-}" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
    export CHEKINANA_ACCESS_TOKEN="$RUNPOD_POD_ID"
  fi
  local token_source="generated-by-app"
  if [ -n "${CHEKINANA_ACCESS_TOKEN:-}" ]; then
    if [ -n "${RUNPOD_POD_ID:-}" ] && [ "$CHEKINANA_ACCESS_TOKEN" = "$RUNPOD_POD_ID" ]; then
      token_source="RUNPOD_POD_ID"
    else
      token_source="CHEKINANA_ACCESS_TOKEN"
    fi
  fi

  log "Starting backend from $BACKEND_DIR on ${HOST}:${PORT}"
  log "Access token source: $token_source"

  cd "$BACKEND_DIR"
  exec "$PYTHON_BIN" -u app.py
}

sync_repo
install_dependencies
start_backend
