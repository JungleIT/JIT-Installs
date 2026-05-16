$ErrorActionPreference = "Stop"

# Office Click-to-Run updater for AIB image builds.
#
# Design (intentionally minimal):
#   - OfficeC2RClient.exe itself checks the CDN for a newer build on the
#     installed channel. That is its job - do not reinvent it by scraping
#     Microsoft Learn HTML or parsing channel GUIDs out of registry.
#   - We snapshot the installed build, kick off /Update, then poll multiple
#     C2R progress signals every 30s until both worker processes exit or we
#     hit a hard cap. Final diff of build number tells us what happened:
#       * build number changed   -> update applied
#       * build number unchanged -> already current (no-op)
#       * workers still running at cap -> log warning, continue build
#
# Why we wait at all (vs fire-and-forget):
#   The deployed AVD session host has Office auto-updates disabled
#   (DisableAutoUpdates.ps1 customizer in AIB), so Office WILL NOT
#   auto-update post-deploy. The image must ship with the latest build
#   or users get a stale Office until manual intervention.
#
# Why we surface stage + download size each poll (vs just process names):
#   Without it the log is just "Waiting for C2R workers" every 30s for an
#   hour and a half with no signal whether anything is actually happening.
#   The build operator stares at it not knowing if the network died, the
#   CDN is slow, or it is genuinely making progress.
#
# ASCII-only on purpose: PS 5.1 reads .ps1 files using the system ANSI
# code page (Windows-1252) when there is no BOM. Non-ASCII characters
# like em-dashes break parsing on the build VM (CommandNotFoundException
# on if/else). Stick to plain ASCII in this file - no smart quotes, no
# em-dashes, no special whitespace.

$updateCmd = "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe"
if (-not (Test-Path $updateCmd)) {
    Write-Log "Office C2R not installed at $updateCmd - skipping" -Level WARN
    return
}

$regPath = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
try {
    $before = (Get-ItemProperty -Path $regPath -Name VersionToReport -ErrorAction Stop).VersionToReport
} catch {
    throw "Could not read installed Office build from $regPath"
}
Write-Log "Installed Office build: $before"

Write-Log "Kicking off OfficeC2RClient /Update (CDN-driven; will no-op if already current)"
Start-Process -FilePath $updateCmd -ArgumentList "/Update User displaylevel=false"
Start-Sleep -Seconds 10

# Helpers used by the poll loop --------------------------------------------

# Reads C2R's current high-level scenario from registry. Values seen during
# an update: STREAM (downloading), APPLY (writing files), FINALIZE (cleanup).
# Returns 'UNKNOWN' if the key is missing or empty (which happens between
# scenarios). Cheap to call - just a registry read.
function Get-C2RScenario {
    try {
        $s = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Scenario" -Name CurrentScenario -ErrorAction Stop).CurrentScenario
        if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
        return $s.ToUpper()
    } catch {
        return 'UNKNOWN'
    }
}

# Sums everything under C2R's download staging folder. This is where the
# CDN stream lands before APPLY moves files into place. Growing size = the
# download is making progress; static size for many cycles = network stall.
# Returns bytes (or 0 if the folder doesn't exist yet).
function Get-DownloadBytes {
    $dl = "C:\Program Files\Microsoft Office\Updates\Download"
    if (-not (Test-Path $dl)) { return 0 }
    try {
        $sum = (Get-ChildItem -Path $dl -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if (-not $sum) { return 0 }
        return [int64]$sum
    } catch {
        return 0
    }
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -lt 1MB)  { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB)  { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

# Poll loop ----------------------------------------------------------------
#
# 90-min hard cap. C2R updates typically finish in 5-30 min; 90 covers a
# large cumulative update on a small SKU in a slow region. If we hit this
# we continue the image build anyway - the update is async and will keep
# running in the background until the build VM is torn down by AIB.

$maxWaitSeconds = 5400
$pollSeconds    = 30
$elapsed        = 0
$workerNames    = @('OfficeC2RClient','OfficeClickToRun')
$prevBytes      = 0
$prevScenario   = ''

while ($elapsed -lt $maxWaitSeconds) {
    $running  = @($workerNames | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue }) | Where-Object { $_ }
    if (-not $running) { break }

    $scenario = Get-C2RScenario
    $bytes    = Get-DownloadBytes
    $delta    = $bytes - $prevBytes
    $deltaStr = if ($delta -gt 0) { '+' + (Format-Bytes $delta) } else { 'no change' }
    $stageHi  = if ($scenario -ne $prevScenario -and $prevScenario -ne '') { ' *NEW STAGE*' } else { '' }
    $workers  = (($running.Name | Select-Object -Unique) -join ',')
    $mm       = [math]::Floor($elapsed / 60)
    $ss       = $elapsed % 60

    Write-Log ("Stage={0,-12} Download={1,-9} ({2,-9}) Workers={3} [elapsed {4:00}:{5:00}]{6}" -f `
        $scenario, (Format-Bytes $bytes), $deltaStr, $workers, $mm, $ss, $stageHi)

    $prevBytes    = $bytes
    $prevScenario = $scenario
    Start-Sleep -Seconds $pollSeconds
    $elapsed += $pollSeconds
}

try {
    $after = (Get-ItemProperty -Path $regPath -Name VersionToReport -ErrorAction Stop).VersionToReport
} catch {
    Write-Log "Could not re-read Office build after update attempt - continuing" -Level WARN
    return
}

if ($after -ne $before) {
    Write-Log "Office updated: $before -> $after"
} elseif ($elapsed -ge $maxWaitSeconds) {
    Write-Log "C2R workers still running after $maxWaitSeconds s - continuing image build (update will finish in background)" -Level WARN
} else {
    Write-Log "Office already at latest published build for its channel ($before) - no update applied"
}
