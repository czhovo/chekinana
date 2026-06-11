#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${CHEKINANA_APP_DIR:-/workspace/chekinana}"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu130}"

cd "$APP_DIR"

if command -v conda >/dev/null 2>&1; then
  echo "[chekinana] creating conda env at $APP_DIR/.conda"
  conda create -p "$APP_DIR/.conda" python=3.11 pip -y
  PYTHON_BIN="$APP_DIR/.conda/bin/python"
else
  echo "[chekinana] conda not found; creating venv at $APP_DIR/.venv"
  python3 -m venv "$APP_DIR/.venv"
  PYTHON_BIN="$APP_DIR/.venv/bin/python"
fi

"$PYTHON_BIN" -m pip install --upgrade pip
"$PYTHON_BIN" -m pip install torch torchvision --index-url "$PYTORCH_INDEX_URL"
"$PYTHON_BIN" -m pip install -r "$APP_DIR/backend/requirements.txt"

"$PYTHON_BIN" - <<'PY'
import torch
print("torch", torch.__version__)
print("cuda", torch.cuda.is_available())
print("gpu", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none")
PY

echo "[chekinana] environment ready"
