# RunPod backend management scripts

These scripts manage the `chekinana` backend Pod.

Defaults:

- Pod ID: stored in `scripts/runpod/runpod.config.json`
- Pod name: `chekinana`
- HTTP port: `8080`
- Network volume ID: `jg5p3opv6h`
- App path inside the Pod: `/workspace/chekinana`

The Pod ID and proxy URL can change after RunPod migration. The PowerShell
scripts auto-discover the current Pod from the configured `podName` or
`networkVolumeId`, update `runpod.config.json`, and rewrite
`wechat-miniprogram/utils/config.js` with the current proxy URL.

## One-time Pod setup

On RunPod, set the Pod start command to:

```bash
bash /workspace/chekinana/scripts/start-backend.sh
```

The backend prints the access token in its startup logs. To keep the same token
after restarts, set this environment variable on the Pod:

```bash
CHEKINANA_ACCESS_TOKEN=your_token
```

If the Python environment does not exist yet, run once inside the Pod:

```bash
cd /workspace/chekinana
chmod +x scripts/*.sh
bash scripts/setup-runpod-env.sh
```

## Local usage

Set your RunPod API key in the current PowerShell session:

```powershell
$env:RUNPOD_API_KEY="your_runpod_api_key"
$env:CHEKINANA_ACCESS_TOKEN="your_backend_token"
```

Start the Pod and wait until `/api/health` returns `ok`:

```powershell
.\scripts\runpod\start-backend-pod.ps1
```

After manually migrating a Pod in the RunPod console, refresh the local Pod ID
and mini-program API URL without starting a test:

```powershell
.\scripts\runpod\sync-runpod-pod.ps1
```

Run an upload/download test:

```powershell
.\scripts\runpod\test-backend-pod.ps1 -ImagePath "imgs\IMG_9227.jpg" -WhiteBalance 1
```

Stop the Pod:

```powershell
.\scripts\runpod\stop-backend-pod.ps1
```

Do not commit `RUNPOD_API_KEY` to Git.
