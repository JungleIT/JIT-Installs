$ErrorActionPreference = "Stop"

$workDir = Join-Path $env:TEMP "teams-avd"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$teamsRegPath = "HKLM:\SOFTWARE\Microsoft\Teams"
New-Item -Path $teamsRegPath -Force | Out-Null
New-ItemProperty -Path $teamsRegPath -Name "IsWVDEnvironment" -Value 1 -PropertyType DWORD -Force | Out-Null
Write-Log "Set Teams AVD registry flag: $teamsRegPath\IsWVDEnvironment=1"

function Invoke-Installer {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$Name,
        [int[]]$SuccessExitCodes = @(0, 3010)
    )

    Write-Log "Running $Name installer..."
    $result = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    if ($result.ExitCode -notin $SuccessExitCodes) {
        throw "$Name installer failed with exit code $($result.ExitCode)"
    }
    Write-Log "$Name installer completed with exit code $($result.ExitCode)"
}

function Test-InstalledDisplayName {
    param([string]$DisplayNamePattern)

    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $regPaths) {
        $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayNamePattern*" } |
            Select-Object -First 1
        if ($entry) { return $true }
    }

    return $false
}

function Test-WebRtcRedirectorInstalled {
    if (Test-InstalledDisplayName -DisplayNamePattern "Remote Desktop WebRTC Redirector") { return $true }
    if (Get-Service -Name "MsRdcWebRTCSvc" -ErrorAction SilentlyContinue) { return $true }
    return $false
}

$vcRedist = Join-Path $workDir "vc_redist.x64.exe"
Invoke-Download -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcRedist
Invoke-Installer -FilePath $vcRedist -ArgumentList "/install /quiet /norestart" -Name "Microsoft Visual C++ Redistributable" -SuccessExitCodes @(0, 3010, 1638)

$webRtcDisplayName = "Remote Desktop WebRTC Redirector Service"
if (Test-WebRtcRedirectorInstalled) {
    Write-Log "$webRtcDisplayName already installed - skipping"
} else {
    $webRtc = Join-Path $workDir "msrdcwebrtcsvc.msi"
    Invoke-Download -Uri "https://aka.ms/msrdcwebrtcsvc/msi" -OutFile $webRtc

    Write-Log "Running $webRtcDisplayName installer..."
    $webRtcResult = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$webRtc`" /quiet /norestart" -Wait -PassThru
    if ($webRtcResult.ExitCode -notin @(0, 3010)) {
        Write-Log "$webRtcDisplayName installer returned $($webRtcResult.ExitCode) - continuing because existing AVD images may already include it" -Level WARN
    } else {
        Write-Log "$webRtcDisplayName installer completed with exit code $($webRtcResult.ExitCode)"
    }
}

$webView = Join-Path $workDir "MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
Invoke-Download -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $webView
Write-Log "Running Microsoft Edge WebView2 Runtime installer..."
$webViewResult = Start-Process -FilePath $webView -ArgumentList "/silent /install" -Wait -PassThru
if ($webViewResult.ExitCode -notin @(0, 3010)) {
    Write-Log "Microsoft Edge WebView2 Runtime installer returned $($webViewResult.ExitCode) - continuing" -Level WARN
} else {
    Write-Log "Microsoft Edge WebView2 Runtime installer completed with exit code $($webViewResult.ExitCode)"
}

$teamsBootstrapper = Join-Path $workDir "teamsbootstrapper.exe"
Invoke-Download -Uri "https://go.microsoft.com/fwlink/?linkid=2243204" -OutFile $teamsBootstrapper
Invoke-Installer -FilePath $teamsBootstrapper -ArgumentList "-p" -Name "New Teams bootstrapper"

$teams = Get-AppxProvisionedPackage -Online |
    Where-Object { $_.DisplayName -eq "MSTeams" -or $_.PackageName -like "MSTeams*" } |
    Select-Object -First 1

if (-not $teams) {
    throw "MSTeams was not found in provisioned packages after bootstrapper install"
}

Write-Log "New Teams provisioned successfully: $($teams.PackageName)"
