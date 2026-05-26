# Standard apps installed/upgraded via winget.
# Find package IDs with: winget search <name>
$WingetApps = @(
    #'7zip.7zip',
    #'Google.Chrome',
    #'Notepad++.Notepad++',
)

# Apps requiring a custom install script at apps/<name>/install.ps1.
# Use for software not in the winget catalog or needing special handling (e.g. Office).
$CustomApps = @(
    'office-update'
)
