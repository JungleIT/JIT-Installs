$ErrorActionPreference = "Stop"

# CDN GUID -> friendly channel name (Office CDN "pr/<GUID>" in HKLM ClickToRun config)
$ChannelGuidMap = @{
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
}

function Get-PlainText {
    param([string]$html)
    $t = [regex]::Replace($html, '<script[^>]*>.*?</script>', ' ', 'IgnoreCase, Singleline')
    $t = [regex]::Replace($t, '<style[^>]*>.*?</style>',   ' ', 'IgnoreCase, Singleline')
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = [regex]::Replace($t, '\s+', ' ')
    return $t.Trim()
}

# 1. Read installed Office configuration
try {
    $regProps             = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction Stop
    $ExistingVersionStr   = $regProps.VersionToReport
    $updateChannelUrlRaw  = $regProps.UpdateChannel
} catch {
    throw "Office not detected (could not read HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration)"
}

# 2. Resolve channel from the GUID embedded in UpdateChannel URL
$friendlyChannel = $null
if ([string]::IsNullOrWhiteSpace($updateChannelUrlRaw)) {
    Write-Log "UpdateChannel registry value is empty - defaulting to 'Current Channel'" -Level WARN
    $friendlyChannel = 'Current Channel'
} else {
    $guidMatch = [regex]::Match($updateChannelUrlRaw, '(?i)\b([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b')
    if ($guidMatch.Success -and $ChannelGuidMap.ContainsKey($guidMatch.Groups[1].Value.ToLower())) {
        $friendlyChannel = $ChannelGuidMap[$guidMatch.Groups[1].Value.ToLower()]
    } else {
        throw "Unrecognized Office UpdateChannel: $updateChannelUrlRaw"
    }
}

if ($friendlyChannel -eq 'Beta Channel') {
    Write-Log "Beta Channel update checking is not supported by this script - skipping" -Level WARN
    return
}

# 3. Convert installed version + derive online-style build (Build.Revision)
try {
    $ExistingVersion = [System.Version]$ExistingVersionStr
} catch {
    throw "Could not parse installed Office version '$ExistingVersionStr'"
}

$installedOnlineBuild = "$($ExistingVersion.Build).$($ExistingVersion.Revision)"
Write-Log "Installed Office: $ExistingVersionStr ($friendlyChannel) - online build $installedOnlineBuild"

# 4. Look up the latest published build for this channel
$onlineBuild = $null
if ($friendlyChannel -eq 'Current Channel (Preview)') {
    $ccpUrl = 'https://learn.microsoft.com/en-us/officeupdates/update-history-current-channel-preview'
    try {
        $ccpHtml = (Invoke-WebRequest -Uri $ccpUrl -UseBasicParsing -ErrorAction Stop).Content
    } catch {
        throw "Could not fetch Current Channel (Preview) update history"
    }
    $m = [regex]::Match($ccpHtml, 'Version\s+\d+\s*\(Build\s+(?<onlineBuild>\d+\.\d+)\)', 'IgnoreCase')
    if ($m.Success) { $onlineBuild = $m.Groups['onlineBuild'].Value }
} else {
    $historyUrl = 'https://learn.microsoft.com/en-us/officeupdates/update-history-microsoft365-apps-by-date'
    try {
        $html = (Invoke-WebRequest -Uri $historyUrl -UseBasicParsing -ErrorAction Stop).Content
    } catch {
        throw "Could not fetch Office update history"
    }

    # Scope to the "Supported Versions" section to avoid false matches in the changelog
    $svMatch   = [regex]::Match($html, '(?is)Supported Versions(?<sec>.*?)(?:Version History|Previous versions|What''s new|</main>|$)')
    $svSection = if ($svMatch.Success) { $svMatch.Groups['sec'].Value } else { $html }
    $textSV    = Get-PlainText $svSection
    $chanEsc   = [regex]::Escape($friendlyChannel)

    $m = [regex]::Match($textSV, $chanEsc + '\s+\d{4}\s+(?<onlineBuild>\d+\.\d+)\b', 'IgnoreCase')
    if ($m.Success) {
        $onlineBuild = $m.Groups['onlineBuild'].Value
    } else {
        # Looser fallback over the whole page
        $fullText = Get-PlainText $html
        $m2 = [regex]::Match($fullText, $chanEsc + '.*?\b(?<onlineBuild>\d{4,5}\.\d{4,5})\b', 'IgnoreCase, Singleline')
        if ($m2.Success) { $onlineBuild = $m2.Groups['onlineBuild'].Value }
    }
}

if (-not $onlineBuild) {
    throw "Could not extract latest online build for channel '$friendlyChannel'"
}
Write-Log "Latest published build for ${friendlyChannel}: $onlineBuild"

# 5. Compare and update if needed
try {
    $installedVerObj = [System.Version]$installedOnlineBuild
    $onlineVerObj    = [System.Version]$onlineBuild
} catch {
    throw "Could not compare builds: installed='$installedOnlineBuild' online='$onlineBuild'"
}

if ($installedVerObj -ge $onlineVerObj) {
    Write-Log "Office is already up to date - skipping"
    return
}

Write-Log "Updating Office from $installedOnlineBuild to $onlineBuild..."

$updateCmd = "C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe"
if (-not (Test-Path $updateCmd)) {
    throw "OfficeC2RClient.exe not found at $updateCmd"
}
Start-Process -FilePath $updateCmd -ArgumentList "/Update User displaylevel=false"

# Poll registry for VersionToReport change.
# Timeout = 90 min (was 20 - too short on small SKUs in slow regions where
# C2R cumulative updates can take 60+ min).
# Non-fatal on timeout: log a warning and return, don't fail the AIB build.
# The update keeps running in the background; worst case the captured
# image has a slightly older build than latest (still updated from prior
# version, just not bleeding-edge).
$maxWaitSeconds = 5400
$pollInterval   = 20
$elapsed        = 0
$NewVersionStr  = $ExistingVersionStr

while (($NewVersionStr -eq $ExistingVersionStr) -and ($elapsed -lt $maxWaitSeconds)) {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval
    Write-Log "Waiting for Office update... ($($maxWaitSeconds - $elapsed)s remaining)"
    try {
        $NewVersionStr = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -Name VersionToReport -ErrorAction Stop).VersionToReport
    } catch {
        Write-Log "Could not read Office version during poll" -Level WARN
    }
}

if ($NewVersionStr -eq $ExistingVersionStr) {
    Write-Log "Office update did not complete within $maxWaitSeconds seconds. Continuing image build; update may finish in background." -Level WARN
} else {
    Write-Log "Office updated successfully: $ExistingVersionStr -> $NewVersionStr"
}
