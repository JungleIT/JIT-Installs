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
# Give C2R a few seconds to spawn the worker process before we look for it
Start-Sleep -Seconds 10

# Two-signal wait, 45-minute cap.
#
# Why both signals:
#   - OfficeC2RClient.exe is the worker process that actually downloads/applies
#     the update. When it exits, the update is done (success or fail). This is
#     deterministic and beats polling registry for VersionToReport, which only
#     gets written near the end of the process.
#   - VersionToReport still confirms the update *actually applied* — guards
#     against the edge case where the process exits without changing the build
#     (e.g. user channel mismatch, no update available after all).
#
# Why non-fatal on timeout (was: throw):
#   - C2R updates take 25-40 minutes on smaller SKUs in slower regions. The old
#     20-minute throw was failing AIB builds even when the update would have
#     finished cleanly a few minutes later.
#   - The update is async — it keeps running in the background. Worst case the
#     captured image has a slightly older Office build; the running session
#     host will then auto-update on next user logon. Better than failing the
#     entire image build (which destroys + recreates ~$$ of compute time).
$maxWaitSeconds = 2700   # 45 minutes
$pollInterval   = 30
$elapsed        = 0
$NewVersionStr  = $ExistingVersionStr
$processGone    = $false

while ($elapsed -lt $maxWaitSeconds) {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval

    # Primary signal: the OfficeC2RClient worker is finished
    $running = Get-Process -Name OfficeC2RClient -ErrorAction SilentlyContinue
    if (-not $running) {
        $processGone = $true
        Write-Log "OfficeC2RClient process has exited — checking applied version"
        try {
            $NewVersionStr = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -Name VersionToReport -ErrorAction Stop).VersionToReport
        } catch {
            Write-Log "Could not read Office version after process exit" -Level WARN
        }
        break
    }

    # Secondary signal: registry version already updated (process may still
    # be doing post-install cleanup but the apply is effectively complete)
    try {
        $NewVersionStr = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -Name VersionToReport -ErrorAction Stop).VersionToReport
        if ($NewVersionStr -ne $ExistingVersionStr) {
            Write-Log "VersionToReport updated to $NewVersionStr (worker still cleaning up) — continuing"
            break
        }
    } catch {
        Write-Log "Could not read Office version during poll" -Level WARN
    }

    Write-Log "Waiting for Office update... ($($maxWaitSeconds - $elapsed)s remaining; OfficeC2RClient still running)"
}

if ($NewVersionStr -eq $ExistingVersionStr) {
    if ($processGone) {
        Write-Log "OfficeC2RClient exited but VersionToReport unchanged ($ExistingVersionStr). Update may have been a no-op or applied without rewriting the marker." -Level WARN
    } else {
        Write-Log "Office update did not finish within $maxWaitSeconds seconds. C2R worker is still running and will complete in the background; captured image may have older build. Continuing image build." -Level WARN
    }
} else {
    Write-Log "Office updated successfully: $ExistingVersionStr -> $NewVersionStr"
}
