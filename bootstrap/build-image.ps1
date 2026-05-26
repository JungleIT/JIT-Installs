#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

# Azure Image Builder runs only this file - everything else must be pulled down first.
$RepoBase   = "https://raw.githubusercontent.com/JungleIT/JIT-Installs/main"
$StagingDir = "C:\ImageBuild\Scripts"
$LogDir     = "C:\ImageBuild\Logs"

New-Item -ItemType Directory -Path $StagingDir, $LogDir -Force | Out-Null
Start-Transcript -Path "$LogDir\build-image.log" -Append

# Force TLS 1.2 - required for GitHub raw and most vendor download CDNs
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-RepoFile {
    param (
        [string]$RelativePath   # e.g. "common/logging.ps1"
    )
    $localPath = Join-Path $StagingDir ($RelativePath -replace "/", "\")
    $localDir  = Split-Path $localPath -Parent
    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
    Invoke-WebRequest -Uri "$RepoBase/$RelativePath" -OutFile $localPath -UseBasicParsing
    return $localPath
}

# Pull down and load shared modules before anything else
. (Get-RepoFile "common/logging.ps1")
. (Get-RepoFile "common/helpers.ps1")

Write-Log "Staging directory: $StagingDir"
Write-Log "Starting image build"

# Pull down app list and load $WingetApps / $CustomApps
. (Get-RepoFile "config/app-list.ps1")

foreach ($pkg in $WingetApps) {
    Write-Log "--- $pkg ---"
    try {
        Install-WingetPackage -PackageId $pkg
    } catch {
        Write-Log "FAILED: $pkg" -Level ERROR
        Write-Log "Exception: $($_.Exception.Message)" -Level ERROR
        Stop-Transcript
        throw
    }
}

foreach ($app in $CustomApps) {
    Write-Log "--- $app ---"
    try {
        $scriptPath = Get-RepoFile "apps/$app/install.ps1"
        & $scriptPath
    } catch {
        Write-Log "FAILED: $app" -Level ERROR
        Write-Log "Exception  : $($_.Exception.Message)" -Level ERROR
        Write-Log "Script     : $($_.InvocationInfo.ScriptName)" -Level ERROR
        Write-Log "Line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -Level ERROR
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
        Stop-Transcript
        throw
    }
}

Write-Log "Image build completed successfully"
Stop-Transcript
