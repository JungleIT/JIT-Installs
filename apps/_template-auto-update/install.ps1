# Template: install latest version from a vendor source (auto-update pattern).
# Use this when there is a discoverable "latest" feed: GitHub Releases API,
# vendor JSON manifest, or a download page that can be regex-scraped.
#
# To use:
#   1. Copy this folder to apps/<appname>/
#   2. Replace the <ALL_CAPS> placeholders below
#   3. Add "<appname>" to config/app-list.ps1

$ErrorActionPreference = "Stop"

# 1. Resolve latest upstream version
#    GitHub Releases example shown; alternatives:
#      Vendor JSON:  $release = Invoke-RestMethod 'https://example.com/version.json'
#      HTML scrape:  $page    = Invoke-WebRequest 'https://example.com/download'
#                    then regex over $page.Links.href or $page.Content
Write-Log "Resolving latest <APPNAME> version..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/<OWNER>/<REPO>/releases/latest"
$asset   = $release.assets | Where-Object { $_.name -match "<INSTALLER_REGEX>" } | Select-Object -First 1
if (-not $asset) { throw "Could not find <APPNAME> installer in latest GitHub release" }
$latestVersion = $release.tag_name.TrimStart("v")
Write-Log "Latest <APPNAME> version: $latestVersion"

# 2. Skip-or-upgrade based on currently installed version
$installedVersion = Get-InstalledVersion -DisplayName "<DISPLAY_NAME_PATTERN>"
if ($installedVersion) {
    Write-Log "Installed <APPNAME> version: $installedVersion"
    if (Test-VersionAtLeast -Have $installedVersion -Need $latestVersion) {
        Write-Log "<APPNAME> is already up to date ($installedVersion) - skipping"
        return
    }
    Write-Log "Upgrading <APPNAME> from $installedVersion to $latestVersion"
} else {
    Write-Log "<APPNAME> not installed - installing version $latestVersion"
}

# 3. Download + install (pick MSI or EXE)
$installer = "$env:TEMP\<APPNAME>.<EXT>"   # .msi or .exe
Invoke-Download -Uri $asset.browser_download_url -OutFile $installer

# --- choose ONE of these ---
Install-MSI -Path $installer
# Install-MSI -Path $installer -AdditionalArgs "ALLUSERS=1 /norestart"
# Install-EXE -Path $installer -Arguments "/S"
# Install-EXE -Path $installer -Arguments "/quiet /norestart"

Write-Log "<APPNAME> $latestVersion installed successfully"
