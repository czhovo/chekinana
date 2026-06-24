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

For a brand-new pod where `/workspace/chekinana` does not exist yet, use this
bootstrap start command once:

```bash
bash -lc 'set -e; mkdir -p /workspace/bootstrap; if [ ! -d /workspace/chekinana/.git ]; then mkdir -p /root/.ssh; chmod 700 /root/.ssh; printf "%s" "$CHEKINANA_GITHUB_SSH_KEY_B64" | tr -d "\r\n " | base64 -d > /root/.ssh/chekinana_github; chmod 600 /root/.ssh/chekinana_github; cat > /root/.ssh/config <<EOF
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
chmod 600 /root/.ssh/config; export GIT_SSH_COMMAND="ssh -F /root/.ssh/config"; git clone --branch "${CHEKINANA_REPO_BRANCH:-main}" --single-branch "${CHEKINANA_REPO_URL:-ssh://git@ssh.github.com:443/czhovo/chekinana.git}" /workspace/chekinana; fi; exec bash /workspace/chekinana/scripts/start-backend.sh'
```

After the first successful clone, change the pod start command back to the
normal command:

```bash
bash /workspace/chekinana/scripts/start-backend.sh
```

## Required environment variables

Set this secret in the RunPod pod environment. Prefer the base64 form because
RunPod's environment-variable value field is a single-line input:

```text
CHEKINANA_GITHUB_SSH_KEY_B64=<base64 encoded private deploy key with read access to czhovo/chekinana>
```

`/root` is not durable across migrations, so the script recreates
`/root/.ssh/chekinana_github` from the RunPod environment on every start. Do
not store the private key in `/workspace` or commit it to Git.

On Windows, create the base64 value with:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\.ssh\chekinana_runpod_ed25519")) | Set-Clipboard
```

The script also accepts `CHEKINANA_GITHUB_SSH_KEY` with a raw multiline key if
your RunPod UI supports it.

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
4. Fails loudly and exits if clone/fetch/checkout/reset fails.
5. Creates or reuses `/workspace/.chekinana/venv`.
6. Installs or updates dependencies when `backend/requirements.txt` changes.
7. Prints PyTorch/CUDA information.
8. Starts `backend/app.py` on `0.0.0.0:8080`.

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

`scripts/runpod/runpod.config.json` intentionally keeps `podId` and
`networkVolumeId` empty after the network-volume reset. Fill `podId` manually
or keep the new pod name as `chekinana-migration` so the helper can discover it.

Run an upload/download smoke test:

```powershell
.\scripts\runpod\test-backend-pod.ps1 -ImagePath "imgs\IMG_9227.jpg" -WhiteBalance 1
```

Stop the pod:

```powershell
.\scripts\runpod\stop-backend-pod.ps1
```

Do not commit `RUNPOD_API_KEY` or any GitHub private key.
