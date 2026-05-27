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

Write-Log "Resolving latest Office Deployment Tool download..."
$confirmationUri = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49117"
$confirmation = Invoke-WebRequest -Uri $confirmationUri -UseBasicParsing
$odtUri = [regex]::Match(
    $confirmation.Content,
    'https://download\.microsoft\.com/download/[^"]+officedeploymenttool[^"]+\.exe'
).Value

if (-not $odtUri) {
    throw "Could not resolve Office Deployment Tool download URL from $confirmationUri"
}

$odtInstaller = Join-Path $workDir "officedeploymenttool.exe"
Invoke-Download -Uri $odtUri -OutFile $odtInstaller

Write-Log "Extracting Office Deployment Tool..."
$extract = Start-Process -FilePath $odtInstaller -ArgumentList "/quiet /extract:`"$odtDir`"" -Wait -PassThru
if ($extract.ExitCode -ne 0) {
    throw "Office Deployment Tool extraction failed with exit code $($extract.ExitCode)"
}

$setup = Join-Path $odtDir "setup.exe"
if (-not (Test-Path $setup)) {
    throw "Office Deployment Tool setup.exe was not found after extraction"
}

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
