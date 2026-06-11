#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${CHEKINANA_APP_DIR:-/workspace/chekinana}"
BACKEND_DIR="$APP_DIR/backend"
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"
THREADS="${THREADS:-6}"

echo "[chekinana] app dir: $APP_DIR"
cd "$APP_DIR"

if [ -d ".git" ]; then
  echo "[chekinana] pulling latest code..."
  git pull --ff-only || echo "[chekinana] git pull skipped/failed; continuing with local code"
fi

if [ -n "${CHEKINANA_PYTHON:-}" ]; then
  PYTHON_BIN="$CHEKINANA_PYTHON"
elif [ -x "$APP_DIR/.conda/bin/python" ]; then
  PYTHON_BIN="$APP_DIR/.conda/bin/python"
elif [ -x "$APP_DIR/.venv/bin/python" ]; then
  PYTHON_BIN="$APP_DIR/.venv/bin/python"
else
  echo "[chekinana] no local Python env found; creating .venv"
  python3 -m venv "$APP_DIR/.venv"
  PYTHON_BIN="$APP_DIR/.venv/bin/python"
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install torch torchvision --index-url "${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu130}"
  "$PYTHON_BIN" -m pip install -r "$BACKEND_DIR/requirements.txt"
fi

echo "[chekinana] python: $("$PYTHON_BIN" -c 'import sys; print(sys.executable)')"
"$PYTHON_BIN" - <<'PY'
import torch
print(f"[chekinana] torch={torch.__version__} cuda={torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"[chekinana] gpu={torch.cuda.get_device_name(0)}")
PY

cd "$BACKEND_DIR"

export HOST="$HOST"
export PORT="$PORT"
export THREADS="$THREADS"
export PYTHONUNBUFFERED=1
export PYTHONIOENCODING=utf-8

echo "[chekinana] starting backend on ${HOST}:${PORT}"
exec "$PYTHON_BIN" -u app.py
