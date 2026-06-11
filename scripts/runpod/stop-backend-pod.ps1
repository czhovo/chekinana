param(
    [string]$PodId,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\RunPodConfig.ps1"

$target = Resolve-RunPodTarget -ConfigPath $ConfigPath -PodId $PodId -Refresh
$stopUrl = "https://rest.runpod.io/v1/pods/$($target.PodId)/stop"

Write-Host "Stopping RunPod pod $($target.PodId) ..."
Invoke-RestMethod -Method Post -Uri $stopUrl -Headers $target.Headers | ConvertTo-Json -Depth 10
Write-Host "Stop request sent."
