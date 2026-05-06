# Template: install from a known download URL (no auto-discovery).
# Use this when there is no public "latest" feed and you have a fixed URL to
# the installer - typical for:
#   - Internal/licensed installers hosted in Azure Blob Storage (use a SAS URI)
#   - Static vendor download links pinned to a known version
#   - GitHub Release assets where you want to pin a specific version
#
# To use:
#   1. Copy this folder to apps/<appname>/
#   2. Edit the config block below
#   3. Add "<appname>" to config/app-list.ps1

$ErrorActionPreference = "Stop"

# --- Configure ---------------------------------------------------------------
$displayName     = "<DISPLAY_NAME_PATTERN>"   # match against ARP DisplayName, e.g. "MyApp"
$expectedVersion = "<X.Y.Z>"                  # the version this URL points to; set to $null to "skip if any version installed"
$downloadUrl     = "<HTTPS_URL>"              # vendor static URL, GitHub release asset, or Azure Blob SAS URI
$installerExt    = "msi"                      # "msi" or "exe"
$installerArgs   = ""                         # extra args - MSI: appended after /qn /norestart, EXE: full silent arg string e.g. "/S" or "/quiet /norestart"
# -----------------------------------------------------------------------------

# Skip-or-upgrade
$installedVersion = Get-InstalledVersion -DisplayName $displayName
if ($installedVersion) {
    Write-Log "Installed $displayName version: $installedVersion"
    if ($expectedVersion) {
        if (Test-VersionAtLeast -Have $installedVersion -Need $expectedVersion) {
            Write-Log "$displayName already at or above $expectedVersion - skipping"
            return
        }
        Write-Log "Upgrading $displayName from $installedVersion to $expectedVersion"
    } else {
        Write-Log "$displayName already installed (any version) - skipping"
        return
    }
} else {
    Write-Log "$displayName not installed - installing $expectedVersion"
}

# Download + install
$installer = "$env:TEMP\$displayName.$installerExt"
Invoke-Download -Uri $downloadUrl -OutFile $installer

switch ($installerExt) {
    "msi"   { Install-MSI -Path $installer -AdditionalArgs $installerArgs }
    "exe"   { Install-EXE -Path $installer -Arguments      $installerArgs }
    default { throw "Unsupported installerExt '$installerExt' - expected 'msi' or 'exe'" }
}

Write-Log "$displayName installed successfully"
