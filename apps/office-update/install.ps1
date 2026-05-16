$ErrorActionPreference = "Stop"

# Office Click-to-Run updater for AIB image builds.
#
# Design (intentionally minimal):
#   - OfficeC2RClient.exe itself checks the CDN for a newer build on the
#     installed channel. That is its job - do not reinvent it by scraping
#     Microsoft Learn HTML or parsing channel GUIDs out of registry.
#   - We snapshot the installed build, kick off /Update, wait for the C2R
#     worker processes to exit (deterministic finish signal), then diff
#     the build. Three outcomes:
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

# 90-min hard cap. C2R updates typically finish in 5-30 min; 90 covers a
# large cumulative update on a small SKU in a slow region. If we hit this
# we continue the image build anyway - the update is async and will keep
# running in the background until the build VM is torn down by AIB.
$maxWaitSeconds = 5400
$pollSeconds    = 30
$elapsed        = 0
$workerNames    = @('OfficeC2RClient','OfficeClickToRun')

while ($elapsed -lt $maxWaitSeconds) {
    $running = @($workerNames | ForEach-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue }) | Where-Object { $_ }
    if (-not $running) { break }
    Write-Log ("Waiting for C2R workers: {0} ({1}s elapsed)" -f (($running.Name | Select-Object -Unique) -join ','), $elapsed)
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
