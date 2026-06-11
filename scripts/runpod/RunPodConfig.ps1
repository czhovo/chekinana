$script:RunPodApiBase = "https://rest.runpod.io/v1"

function Get-RunPodConfigPath {
    param([string]$ConfigPath)

    if ($ConfigPath) {
        return $ConfigPath
    }

    return (Join-Path $PSScriptRoot "runpod.config.json")
}

function Get-RunPodConfig {
    param([string]$ConfigPath)

    $resolvedPath = Get-RunPodConfigPath -ConfigPath $ConfigPath
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "RunPod config not found: $resolvedPath"
    }

    $config = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName "_path" -NotePropertyValue $resolvedPath -Force
    return $config
}

function Save-RunPodConfig {
    param([Parameter(Mandatory = $true)]$Config)

    $path = $Config._path
    $copy = [ordered]@{}
    foreach ($property in $Config.PSObject.Properties) {
        if ($property.Name -ne "_path") {
            $copy[$property.Name] = $property.Value
        }
    }

    $copy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-RunPodHeaders {
    if (-not $env:RUNPOD_API_KEY) {
        throw "RUNPOD_API_KEY is not set. Set it first: `$env:RUNPOD_API_KEY='your_key'"
    }

    return @{ Authorization = "Bearer $env:RUNPOD_API_KEY" }
}

function Get-RunPodBaseUrl {
    param(
        [Parameter(Mandatory = $true)][string]$PodId,
        [Parameter(Mandatory = $true)][int]$HttpPort
    )

    return "https://$PodId-$HttpPort.proxy.runpod.net"
}

function Get-RunPodList {
    param([hashtable]$Headers)

    return Invoke-RestMethod -Method Get -Uri "$script:RunPodApiBase/pods" -Headers $Headers -TimeoutSec 30
}

function Select-RunPodCandidate {
    param(
        [Parameter(Mandatory = $true)]$Pods,
        [Parameter(Mandatory = $true)]$Config,
        [string]$PodId
    )

    $matches = @()

    if ($PodId) {
        $matches = @($Pods | Where-Object { $_.id -eq $PodId })
    }

    if ($Config.autoDiscover -ne $false) {
        $discovered = @($Pods | Where-Object {
            $nameMatches = $Config.podName -and $_.name -eq $Config.podName
            $volumeMatches = $Config.networkVolumeId -and $_.networkVolume -and $_.networkVolume.id -eq $Config.networkVolumeId
            $nameMatches -or $volumeMatches
        })

        if ($discovered.Count -gt 0) {
            $matches = $discovered
        }
    }

    if ($matches.Count -eq 0 -and $PodId) {
        return $null
    }

    $active = @($matches | Where-Object { $_.desiredStatus -ne "TERMINATED" })
    if ($active.Count -gt 0) {
        $matches = $active
    }

    return @($matches | Sort-Object `
        @{ Expression = { if ($_.lastStartedAt) { [datetime]$_.lastStartedAt } else { [datetime]::MinValue } }; Descending = $true }, `
        @{ Expression = { $_.id }; Descending = $true } |
        Select-Object -First 1)[0]
}

function Update-WechatRunPodConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$BaseUrl
    )

    if (-not $Config.wechatConfigPath) {
        return
    }

    $configDir = Split-Path -Parent $Config._path
    $targetPath = [System.IO.Path]::GetFullPath((Join-Path $configDir $Config.wechatConfigPath))
    if (-not (Test-Path -LiteralPath $targetPath)) {
        Write-Warning "Wechat config not found, skip update: $targetPath"
        return
    }

    $content = Get-Content -LiteralPath $targetPath -Raw
    $updated = $content -replace 'const API_BASE_URL = ".*?";', "const API_BASE_URL = `"$BaseUrl`";"
    if ($updated -ne $content) {
        Set-Content -LiteralPath $targetPath -Value $updated -Encoding UTF8
        Write-Host "Updated WeChat API_BASE_URL: $BaseUrl"
    }
}

function Resolve-RunPodTarget {
    param(
        [string]$ConfigPath,
        [string]$PodId,
        [switch]$Refresh
    )

    $config = Get-RunPodConfig -ConfigPath $ConfigPath
    $headers = Get-RunPodHeaders
    $candidate = $null

    if ($Refresh -or $config.autoDiscover -ne $false -or -not $PodId) {
        $pods = Get-RunPodList -Headers $headers
        $candidate = Select-RunPodCandidate -Pods $pods -Config $config -PodId $(if ($PodId) { $PodId } else { $config.podId })
    }

    if ($candidate) {
        $PodId = $candidate.id
    } elseif (-not $PodId) {
        $PodId = $config.podId
    }

    if (-not $PodId) {
        throw "No RunPod pod id found. Set podId in $($config._path), pass -PodId, or configure podName/networkVolumeId for auto discovery."
    }

    $httpPort = if ($config.httpPort) { [int]$config.httpPort } else { 8080 }
    $baseUrl = Get-RunPodBaseUrl -PodId $PodId -HttpPort $httpPort

    if ($config.podId -ne $PodId) {
        Write-Host "RunPod pod id changed: $($config.podId) -> $PodId"
        $config.podId = $PodId
        Save-RunPodConfig -Config $config
    }

    Update-WechatRunPodConfig -Config $config -BaseUrl $baseUrl

    return [pscustomobject]@{
        PodId = $PodId
        BaseUrl = $baseUrl
        HttpPort = $httpPort
        Headers = $headers
        Config = $config
        Pod = $candidate
    }
}
