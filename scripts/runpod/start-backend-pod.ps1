param(
    [string]$PodId,
    [string]$BaseUrl,
    [string]$ConfigPath,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\RunPodConfig.ps1"

$target = Resolve-RunPodTarget -ConfigPath $ConfigPath -PodId $PodId -Refresh
if (-not $BaseUrl) {
    $BaseUrl = $target.BaseUrl
}
$startUrl = "https://rest.runpod.io/v1/pods/$($target.PodId)/start"

Write-Host "Starting RunPod pod $($target.PodId) ..."
try {
    Invoke-RestMethod -Method Post -Uri $startUrl -Headers $target.Headers | Out-Null
} catch {
    Write-Warning "Start request failed, refreshing pod discovery once: $($_.Exception.Message)"
    $refreshed = Resolve-RunPodTarget -ConfigPath $ConfigPath -Refresh
    if ($refreshed.PodId -ne $target.PodId) {
        $target = $refreshed
        if (-not $PSBoundParameters.ContainsKey("BaseUrl")) {
            $BaseUrl = $target.BaseUrl
        }
        $startUrl = "https://rest.runpod.io/v1/pods/$($target.PodId)/start"
        Write-Host "Retrying RunPod pod $($target.PodId) ..."
        Invoke-RestMethod -Method Post -Uri $startUrl -Headers $target.Headers | Out-Null
    } else {
        Write-Warning "Start request failed or pod may already be running: $($_.Exception.Message)"
    }
}

Write-Host "Waiting for backend health: $BaseUrl/api/health"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    try {
        $health = Invoke-RestMethod -Uri "$BaseUrl/api/health" -TimeoutSec 10
        if ($health.status -eq "ok") {
            Write-Host "Backend ready."
            $health | ConvertTo-Json -Depth 5
            exit 0
        }
    } catch {
        Write-Host "." -NoNewline
    }
    Start-Sleep -Seconds 5
}

throw "Timed out waiting for backend health after $TimeoutSeconds seconds."
