function Resolve-Winget {
    # AIB runs as SYSTEM — winget lives under WindowsApps which isn't in SYSTEM's PATH.
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $exe = Get-Item "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
               -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1 -ExpandProperty FullName
    if ($exe) { return $exe }

    # App Installer is genuinely missing — provision it from GitHub releases.
    Write-Log "winget not found — bootstrapping App Installer" -Level WARN
    $tmp = "C:\ImageBuild\winget-bootstrap"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Invoke-WebRequest -Uri "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx" `
        -OutFile "$tmp\VCLibs.appx" -UseBasicParsing
    Add-AppxProvisionedPackage -Online -PackagePath "$tmp\VCLibs.appx" -SkipLicense | Out-Null

    $release = Invoke-RestMethod "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
    $bundle  = $release.assets | Where-Object { $_.name -like "Microsoft.DesktopAppInstaller_*.msixbundle" } |
               Select-Object -First 1
    $license = $release.assets | Where-Object { $_.name -like "*_License1.xml" } |
               Select-Object -First 1
    Invoke-WebRequest -Uri $bundle.browser_download_url  -OutFile "$tmp\winget.msixbundle" -UseBasicParsing
    Invoke-WebRequest -Uri $license.browser_download_url -OutFile "$tmp\license.xml"       -UseBasicParsing
    Add-AppxProvisionedPackage -Online -PackagePath "$tmp\winget.msixbundle" `
        -LicensePath "$tmp\license.xml" | Out-Null
    Write-Log "App Installer provisioned"

    $exe = Get-Item "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe" `
               -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1 -ExpandProperty FullName
    if ($exe) { return $exe }

    throw "winget.exe not found even after bootstrap — check App Installer provisioning logs."
}

function Install-WingetPackage {
    param([string]$PackageId)
    Write-Log "Processing: $PackageId"

    $winget = Resolve-Winget

    # Try upgrade first — no-op if already current, upgrades if outdated
    & $winget upgrade --id $PackageId --exact --silent `
        --accept-package-agreements --accept-source-agreements 2>&1 |
        ForEach-Object { Write-Log "  $_" }

    if ($LASTEXITCODE -eq 0) {
        Write-Log "$PackageId upgraded successfully"
        return
    }

    # 0x8A150047 = no applicable upgrade (already at latest)
    if ($LASTEXITCODE -eq -1978335161) {
        Write-Log "$PackageId already up to date - skipping"
        return
    }

    # Package not installed — fall through to install
    Write-Log "$PackageId not found by upgrade (exit $LASTEXITCODE) - running install"
    & $winget install --id $PackageId --exact --silent `
        --accept-package-agreements --accept-source-agreements `
        --scope machine 2>&1 |
        ForEach-Object { Write-Log "  $_" }

    # 0x8A150039 = already installed at this version — treat as success
    if ($LASTEXITCODE -notin @(0, -1978335175)) {
        throw "winget install '$PackageId' failed (exit code $LASTEXITCODE)"
    }
    Write-Log "$PackageId installed successfully"
}

function Invoke-Download {
    param (
        [string]$Uri,
        [string]$OutFile
    )
    Write-Log "Downloading: $Uri"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
    } catch {
        throw "Failed to download $Uri - $_"
    }
}

function Install-MSI {
    param (
        [string]$Path,
        [string]$AdditionalArgs = ""
    )
    $msiArgs = "/i `"$Path`" /qn /norestart $AdditionalArgs".Trim()
    Write-Log "Running MSI installer: $Path"
    $result = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
    if ($result.ExitCode -notin @(0, 3010)) {
        throw "MSI install failed with exit code $($result.ExitCode)"
    }
}

function Install-EXE {
    param (
        [string]$Path,
        [string]$Arguments
    )
    Write-Log "Running EXE installer: $Path"
    $result = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($result.ExitCode -notin @(0, 3010)) {
        throw "EXE install failed with exit code $($result.ExitCode)"
    }
}

function Get-InstalledVersion {
    param ([string]$DisplayName)
    $regPaths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $regPaths) {
        $entry = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like "*$DisplayName*" } |
                 Select-Object -First 1
        if ($entry) { return $entry.DisplayVersion }
    }
    return $null
}

function Test-VersionAtLeast {
    param(
        [string]$Have,
        [string]$Need
    )
    try {
        return ([System.Version]$Have -ge [System.Version]$Need)
    } catch {
        Write-Log "Could not parse versions ('$Have' vs '$Need') - treating as needs-upgrade" -Level WARN
        return $false
    }
}
