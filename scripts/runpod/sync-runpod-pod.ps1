param(
    [string]$PodId,
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\RunPodConfig.ps1"

$target = Resolve-RunPodTarget -ConfigPath $ConfigPath -PodId $PodId -Refresh

[pscustomobject]@{
    podId = $target.PodId
    baseUrl = $target.BaseUrl
    httpPort = $target.HttpPort
} | ConvertTo-Json -Depth 5
