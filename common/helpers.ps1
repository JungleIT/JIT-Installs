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
