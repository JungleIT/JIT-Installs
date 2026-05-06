$ErrorActionPreference = "Stop"

Write-Log "Resolving latest 7-Zip version..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest"
$asset = $release.assets | Where-Object { $_.name -match "7z\d+-x64\.msi$" } | Select-Object -First 1
if (-not $asset) { throw "Could not find 7-Zip x64 MSI in latest GitHub release" }
$latestVersion = $release.tag_name.TrimStart("v")
Write-Log "Latest 7-Zip version: $latestVersion"

$installedVersion = Get-InstalledVersion -DisplayName "7-Zip"
if ($installedVersion) {
    Write-Log "Installed 7-Zip version: $installedVersion"
    if (Test-VersionAtLeast -Have $installedVersion -Need $latestVersion) {
        Write-Log "7-Zip is already up to date ($installedVersion) - skipping"
        return
    }
    Write-Log "Upgrading 7-Zip from $installedVersion to $latestVersion"
} else {
    Write-Log "7-Zip not installed - installing version $latestVersion"
}

$installer = "$env:TEMP\7zip.msi"
Invoke-Download -Uri $asset.browser_download_url -OutFile $installer
Install-MSI -Path $installer
Write-Log "7-Zip $latestVersion installed successfully"
