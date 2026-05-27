$ErrorActionPreference = "Stop"

$officeConfigReg = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"
$before = (Get-ItemProperty $officeConfigReg -ErrorAction SilentlyContinue).VersionToReport
Write-Log "Office version before ODT configure: $before"

$workDir = Join-Path $env:TEMP "office-odt-update"
$odtDir = Join-Path $workDir "odt"
New-Item -ItemType Directory -Path $workDir, $odtDir -Force | Out-Null

$configPath = Join-Path $workDir "configuration.xml"
if (Get-Command Get-SAFile -ErrorAction SilentlyContinue) {
    Write-Log "Downloading Office ODT configuration from script storage..."
    Copy-Item -Path (Get-SAFile "apps/office-update/configuration.xml") -Destination $configPath -Force
} else {
    Write-Log "Using local Office ODT configuration..."
    Copy-Item -Path (Join-Path $PSScriptRoot "configuration.xml") -Destination $configPath -Force
}

$setup = Join-Path $odtDir "setup.exe"
Invoke-Download -Uri "https://officecdn.microsoft.com/pr/wsus/setup.exe" -OutFile $setup

Write-Log "Running Office Deployment Tool configure..."
$result = Start-Process -FilePath $setup -ArgumentList "/configure `"$configPath`"" -Wait -PassThru
if ($result.ExitCode -notin @(0, 3010)) {
    throw "Office Deployment Tool configure failed with exit code $($result.ExitCode)"
}

$after = (Get-ItemProperty $officeConfigReg -ErrorAction SilentlyContinue).VersionToReport
if ($before -and $after -and $after -ne $before) {
    Write-Log "Office updated successfully: $before -> $after"
} elseif ($after) {
    Write-Log "Office ODT configure completed; version is $after"
} else {
    Write-Log "Office ODT configure completed, but final Office version could not be read" -Level WARN
}
