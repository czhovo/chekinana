# RunPod backend startup

This directory contains local PowerShell helpers for managing the Chekinana
backend pod. The current pod setup no longer assumes a RunPod network volume.
The backend repo is kept under `/workspace/chekinana`, and the pod start command
syncs GitHub on every boot before starting Flask.

## Existing startup variants in this repo

The repo currently contains these backend startup paths:

- `scripts/start-backend.sh`
  - Production RunPod start command.
  - Syncs GitHub into `/workspace/chekinana`, prepares `/root/.ssh`, creates or
    reuses a Python environment under `/workspace/.chekinana/venv`, installs
    dependencies, then runs `backend/app.py` on port `8080`.
- `scripts/setup-runpod-env.sh`
  - Older one-time environment setup helper.
  - It assumes `/workspace/chekinana` already exists and installs dependencies
    into `.conda` or `.venv` inside the repo. It is kept for reference, but the
    new `start-backend.sh` is the preferred path.
- `Dockerfile`
  - Container path for a plain Python image. It copies `backend/` into `/app`
    and runs `python -u app.py`.
  - This does not handle GitHub sync or RunPod migration.
- `README.md`
  - Local/manual backend path: `cd backend` then `python app.py`.
  - Useful for local smoke work, not for production RunPod startup.

## New pod configuration

Use a GPU RunPod template with Python 3.11, CUDA-compatible PyTorch support, Git,
and OpenSSH client. If Git or OpenSSH are missing, `start-backend.sh` attempts to
install them with `apt-get`.

Set the pod start command to:

```bash
bash /workspace/chekinana/scripts/start-backend.sh
```

For a brand-new pod, or any pod that may migrate between machines, use this
bootstrap start command. It syncs GitHub on every start and retries transient
clone/fetch failures three times with a 10 second delay:

```bash
bash -lc 'set -e; APP="${CHEKINANA_APP_DIR:-/workspace/chekinana}"; REPO="${CHEKINANA_REPO_URL:-ssh://git@ssh.github.com:443/czhovo/chekinana.git}"; BRANCH="${CHEKINANA_REPO_BRANCH:-main}"; ATTEMPTS="${CHEKINANA_GIT_SYNC_ATTEMPTS:-3}"; DELAY="${CHEKINANA_GIT_SYNC_RETRY_SECONDS:-10}"; mkdir -p /root/.ssh /workspace/bootstrap; chmod 700 /root/.ssh; printf "%s\n" "$CHEKINANA_GITHUB_SSH_KEY" | sed "s/\r$//" > /root/.ssh/chekinana_github; chmod 600 /root/.ssh/chekinana_github; cat > /root/.ssh/config <<EOF
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile /root/.ssh/chekinana_github
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
Host ssh.github.com
  Port 443
  User git
  IdentityFile /root/.ssh/chekinana_github
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
chmod 600 /root/.ssh/config; export GIT_SSH_COMMAND="ssh -F /root/.ssh/config -o ServerAliveInterval=30 -o ServerAliveCountMax=3"; run_retry(){ desc="$1"; shift; n=1; while true; do "$@" && return 0; if [ "$n" -ge "$ATTEMPTS" ]; then echo "[chekinana:start:ERROR] $desc failed after $ATTEMPTS attempts" >&2; return 1; fi; echo "[chekinana:start] $desc failed on attempt $n/$ATTEMPTS; retrying in ${DELAY}s"; sleep "$DELAY"; n=$((n+1)); done; }; if [ -d "$APP/.git" ]; then git -C "$APP" remote set-url origin "$REPO"; run_retry "GitHub fetch" git -C "$APP" fetch --prune origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; run_retry "Git checkout" git -C "$APP" checkout -B "$BRANCH" "origin/$BRANCH"; run_retry "Git reset" git -C "$APP" reset --hard "origin/$BRANCH"; else rm -rf "$APP"; run_retry "GitHub clone" git clone --branch "$BRANCH" --single-branch "$REPO" "$APP"; fi; unset CHEKINANA_GITHUB_SSH_KEY_B64 GITHUB_SSH_PRIVATE_KEY_B64; export CHEKINANA_GIT_SYNC_ATTEMPTS=3 CHEKINANA_GIT_SYNC_RETRY_SECONDS=10; exec bash "$APP/scripts/start-backend.sh"'
```

## Required environment variables

Set this secret in the RunPod pod environment:

```text
CHEKINANA_GITHUB_SSH_KEY={{ RUNPOD_SECRET_CHEKINANA_GITHUB_SSH_KEY }}
```

`/root` is not durable across migrations, so the script recreates
`/root/.ssh/chekinana_github` from the RunPod environment on every start. Do
not store the private key in `/workspace` or commit it to Git.

The referenced RunPod Secret must contain the complete private key text:

```text
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

The script still accepts `CHEKINANA_GITHUB_SSH_KEY_B64` as a legacy fallback,
but `CHEKINANA_GITHUB_SSH_KEY` is preferred and takes precedence.

Optional variables:

```text
CHEKINANA_REPO_URL=ssh://git@ssh.github.com:443/czhovo/chekinana.git
CHEKINANA_REPO_BRANCH=main
CHEKINANA_APP_DIR=/workspace/chekinana
CHEKINANA_STATE_DIR=/workspace/.chekinana
PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
PORT=8080
HOST=0.0.0.0
THREADS=6
```

Token behavior:

- If `CHEKINANA_ACCESS_TOKEN` is set, the backend uses it.
- Otherwise, RunPod's `RUNPOD_POD_ID` is used as the access token.
- This preserves the production pod-ID token flow used by the mini program.

## What the start command does

On every pod start:

1. Creates `/workspace/.chekinana` for Python, pip, Hugging Face, Torch, and
   ModelScope caches.
2. Recreates `/root/.ssh` from the RunPod environment.
3. Clones or fetches `CHEKINANA_REPO_BRANCH` from GitHub.
4. Retries GitHub clone/fetch/checkout/reset on temporary network failures.
   Defaults: `CHEKINANA_GIT_SYNC_ATTEMPTS=3` and
   `CHEKINANA_GIT_SYNC_RETRY_SECONDS=10`.
5. Fails loudly and exits if GitHub sync still fails after all retries.
6. Creates or reuses `/workspace/.chekinana/venv`.
7. Installs or updates dependencies when `backend/requirements.txt` changes.
8. Prints PyTorch/CUDA information.
9. Starts `backend/app.py` on `0.0.0.0:8080`.

The script intentionally does not continue with stale code when GitHub sync
fails.

## Local helper scripts

Set your RunPod API key in PowerShell:

```powershell
$env:RUNPOD_API_KEY="your_runpod_api_key"
```

Start the pod and wait for `/api/health`:

```powershell
.\scripts\runpod\start-backend-pod.ps1
```

Refresh the local pod id and mini-program API URL after recreating/migrating a
pod:

```powershell
.\scripts\runpod\sync-runpod-pod.ps1
```

`scripts/runpod/runpod.config.json` stores the latest active pod id. After a
manual RunPod migration, update it or run `sync-runpod-pod.ps1`.

Run an upload/download smoke test:

```powershell
.\scripts\runpod\test-backend-pod.ps1 -ImagePath "imgs\IMG_9227.jpg" -WhiteBalance 1
```

Stop the pod:

```powershell
.\scripts\runpod\stop-backend-pod.ps1
```

Do not commit `RUNPOD_API_KEY` or any GitHub private key.
