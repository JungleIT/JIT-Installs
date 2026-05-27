$ErrorActionPreference = "Stop"

$c2r = "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe"
if (-not (Test-Path $c2r)) {
    Write-Log "OfficeC2RClient.exe not found - Office may not be installed" -Level WARN
    return
}

$before = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue).VersionToReport
Write-Log "Office version before update: $before"

Write-Log "Triggering Office update via OfficeC2RClient..."
Start-Process -FilePath $c2r -ArgumentList "/update user displaylevel=false forceappshutdown=true"

# Poll until VersionToReport changes or timeout (30 min)
$deadline = (Get-Date).AddMinutes(30)
$after = $before
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 30
    $after = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction SilentlyContinue).VersionToReport
    if ($after -ne $before) { break }
    Write-Log "Waiting for Office update... ($([int]($deadline - (Get-Date)).TotalSeconds)s remaining)"
}

if ($after -ne $before) {
    Write-Log "Office updated: $before -> $after"
} else {
    Write-Log "Office version unchanged after 30 min ($before) - already current or update running in background" -Level WARN
}
