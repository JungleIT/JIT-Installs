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

$vcRedist = Join-Path $workDir "vc_redist.x64.exe"
Invoke-Download -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $vcRedist
Invoke-Installer -FilePath $vcRedist -ArgumentList "/install /quiet /norestart" -Name "Microsoft Visual C++ Redistributable"

$webRtc = Join-Path $workDir "msrdcwebrtcsvc.msi"
Invoke-Download -Uri "https://aka.ms/msrdcwebrtcsvc/msi" -OutFile $webRtc
Invoke-Installer -FilePath "msiexec.exe" -ArgumentList "/i `"$webRtc`" /quiet /norestart" -Name "Remote Desktop WebRTC Redirector Service"

$webView = Join-Path $workDir "MicrosoftEdgeWebView2RuntimeInstallerX64.exe"
Invoke-Download -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -OutFile $webView
Invoke-Installer -FilePath $webView -ArgumentList "/silent /install" -Name "Microsoft Edge WebView2 Runtime"

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
