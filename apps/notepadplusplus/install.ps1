$ErrorActionPreference = "Stop"

Write-Log "Resolving latest Notepad++ version..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest"
$asset = $release.assets | Where-Object { $_.name -match "Installer\.x64\.exe$" } | Select-Object -First 1
if (-not $asset) { throw "Could not find Notepad++ x64 installer in latest GitHub release" }
$latestVersion = $release.tag_name.TrimStart("v")
Write-Log "Latest Notepad++ version: $latestVersion"

$installedVersion = Get-InstalledVersion -DisplayName "Notepad++"
if ($installedVersion) {
    Write-Log "Installed Notepad++ version: $installedVersion"
    if (Test-VersionAtLeast -Have $installedVersion -Need $latestVersion) {
        Write-Log "Notepad++ is already up to date ($installedVersion) - skipping"
        return
    }
    Write-Log "Upgrading Notepad++ from $installedVersion to $latestVersion"
} else {
    Write-Log "Notepad++ not installed - installing version $latestVersion"
}

$installer = "$env:TEMP\npp-installer.exe"
Invoke-Download -Uri $asset.browser_download_url -OutFile $installer
Install-EXE -Path $installer -Arguments "/S"
Write-Log "Notepad++ $latestVersion installed successfully"
