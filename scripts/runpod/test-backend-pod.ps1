param(
    [string]$BaseUrl,
    [string]$PodId,
    [string]$ConfigPath,
    [string]$ImagePath = "imgs\IMG_9227.jpg",
    [string]$OutputDir = "pipeline_test_outputs\runpod_auto",
    [ValidateSet("0", "1")]
    [string]$WhiteBalance = "1",
    [string]$AuthToken = $env:CHEKINANA_ACCESS_TOKEN,
    [int]$TimeoutSeconds = 360
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\RunPodConfig.ps1"

$target = $null
if (-not $BaseUrl) {
    $target = Resolve-RunPodTarget -ConfigPath $ConfigPath -PodId $PodId -Refresh
    $BaseUrl = $target.BaseUrl
    if (-not $PodId) {
        $PodId = $target.PodId
    }
} elseif (-not $PodId -and $BaseUrl -match "https?://([a-z0-9]+)-\d+\.proxy\.runpod\.net") {
    $PodId = $Matches[1]
}

if (-not $AuthToken -and $PodId) {
    $AuthToken = $PodId
}

if (-not (Test-Path -LiteralPath $ImagePath)) {
    throw "Image not found: $ImagePath"
}

if (-not $AuthToken) {
    throw "Auth token is required. Pass -AuthToken, pass -PodId, use a RunPod proxy -BaseUrl, or set CHEKINANA_ACCESS_TOKEN."
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host "Checking backend health..."
$health = Invoke-RestMethod -Uri "$BaseUrl/api/health" -TimeoutSec 30
$health | ConvertTo-Json -Depth 5 | Tee-Object -FilePath (Join-Path $OutputDir "health.json")

Write-Host "Verifying auth token..."
$verify = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/auth/verify" -Headers @{ "X-Cheki-Token" = $AuthToken } -Body (@{ token = $AuthToken } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 30
$verify | ConvertTo-Json -Depth 5 | Tee-Object -FilePath (Join-Path $OutputDir "auth.json")

Write-Host "Submitting image: $ImagePath wb=$WhiteBalance"
$submitPath = Join-Path $OutputDir "submit.json"
$submitJson = curl.exe -s -X POST -H "X-Cheki-Token: $AuthToken" -F "image=@$ImagePath" -F "wb=$WhiteBalance" -F "token=$AuthToken" "$BaseUrl/api/process"
$submitJson | Tee-Object -FilePath $submitPath
$submit = $submitJson | ConvertFrom-Json
if (-not $submit.task_id) {
    throw "Submit failed: $submitJson"
}

$taskId = $submit.task_id
Write-Host "Task: $taskId"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$status = $null
while ((Get-Date) -lt $deadline) {
    $statusJson = curl.exe -s -H "X-Cheki-Token: $AuthToken" "$BaseUrl/api/status/$taskId"
    $statusJson | Tee-Object -FilePath (Join-Path $OutputDir "status.json") | Out-Null
    $status = $statusJson | ConvertFrom-Json
    Write-Host "status=$($status.status) phase=$($status.phase) results=$($status.results_count)"
    if ($status.status -eq "done" -or $status.status -eq "failed") {
        break
    }
    Start-Sleep -Seconds 3
}

if ($status.status -ne "done") {
    throw "Task did not finish successfully: $($status | ConvertTo-Json -Depth 10)"
}

foreach ($result in $status.results) {
    $safeLabel = ($result.label -replace '[\\/:*?"<>|#\s]+', '_').Trim('_')
    $outFile = Join-Path $OutputDir ("result_{0}_{1}_{2}.png" -f $result.id, $result.type, $safeLabel)
    curl.exe -s -L -H "X-Cheki-Token: $AuthToken" "$BaseUrl/api/result/$taskId/$($result.id)" -o $outFile
    Write-Host "Downloaded $outFile"
}

Write-Host "Done. Output: $OutputDir"
