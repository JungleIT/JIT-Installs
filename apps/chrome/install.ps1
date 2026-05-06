$ErrorActionPreference = "Stop"

Write-Log "Resolving latest Chrome version..."
$response = Invoke-RestMethod -Uri "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Windows&num=1"
if (-not $response -or [string]::IsNullOrWhiteSpace($response[0].version)) {
    throw "Chromium Dash returned no version data"
}
$latestVersion = $response[0].version
Write-Log "Latest Chrome version: $latestVersion"

$installedVersion = Get-InstalledVersion -DisplayName "Google Chrome"
if ($installedVersion) {
    Write-Log "Installed Chrome version: $installedVersion"
    if (Test-VersionAtLeast -Have $installedVersion -Need $latestVersion) {
        Write-Log "Chrome is already up to date ($installedVersion) - skipping"
        return
    }
    Write-Log "Upgrading Chrome from $installedVersion to $latestVersion"
} else {
    Write-Log "Chrome not installed - installing version $latestVersion"
}

$installer = "$env:TEMP\chrome.msi"
Invoke-Download -Uri "https://dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi" -OutFile $installer
Install-MSI -Path $installer
Write-Log "Chrome $latestVersion installed successfully"
