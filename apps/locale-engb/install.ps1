$ErrorActionPreference = "Stop"

$Culture    = 'en-GB'
$UiLanguage = 'en-GB'
$GeoId      = 242                  # United Kingdom
$TimeZoneId = 'GMT Standard Time'

Write-Log "Configuring locale: Culture=$Culture UiLanguage=$UiLanguage GeoId=$GeoId TimeZone=$TimeZoneId"

# 1. Current user (build account)
Write-Log "Setting culture for current user..."
Set-Culture -CultureInfo $Culture

Write-Log "Setting Windows UI language list..."
$LangList = New-WinUserLanguageList -Language $UiLanguage
Set-WinUserLanguageList -LanguageList $LangList -Force

Write-Log "Setting home location (GeoId $GeoId)..."
Set-WinHomeLocation -GeoId $GeoId

Write-Log "Setting system locale (non-Unicode)..."
Set-WinSystemLocale -SystemLocale $Culture

Write-Log "Setting default input method override (UK English keyboard)..."
Set-WinDefaultInputMethodOverride -InputTip '0809:00000809'

Write-Log "Disabling 'Welcome experience' language sync opt-out..."
Set-WinCultureFromLanguageListOptOut -OptOut $false

# 2. Time zone
Write-Log "Setting time zone to $TimeZoneId..."
Set-TimeZone -Id $TimeZoneId

# Format values for default user + system accounts. [char]0x00A3 = GBP symbol;
# encoded this way so the file is safe regardless of how PowerShell 5.1 reads
# its source encoding (literal raw byte gets misread as mojibake on CP1252).
$intlValues = @{
    'LocaleName'      = $Culture
    'sShortDate'      = 'dd/MM/yyyy'
    'sLongDate'       = 'dd MMMM yyyy'
    'sShortTime'      = 'HH:mm'
    'sTimeFormat'     = 'HH:mm:ss'
    'iFirstDayOfWeek' = '0'                          # 0 = Monday
    'iDate'           = '1'                          # dd/MM/yyyy
    'iTime'           = '1'                          # 24-hour
    'iTLZero'         = '1'                          # leading zero on hours
    'sCountry'        = 'United Kingdom'
    'sLanguage'       = 'ENG'
    'sCurrency'       = [string][char]0x00A3
    'iCurrency'       = '0'
    'iMeasure'        = '0'                          # 0 = metric
    'sDecimal'        = '.'
    'sThousand'       = ','
    'sList'           = ','
}

# 3. Default user profile (NTUSER.DAT) — critical for AVD: new users inherit
Write-Log "Loading default user registry hive..."
$defaultHive = 'C:\Users\Default\NTUSER.DAT'
$regRoot     = 'HKLM\DEFAULTUSER'

& reg.exe load $regRoot $defaultHive | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to load default user hive (exit $LASTEXITCODE)" }

try {
    $intlPath = "Registry::$regRoot\Control Panel\International"
    Write-Log "Writing en-GB format values to default user profile..."
    foreach ($name in $intlValues.Keys) {
        New-ItemProperty -Path $intlPath -Name $name -Value $intlValues[$name] -PropertyType String -Force | Out-Null
    }

    $geoPath = "Registry::$regRoot\Control Panel\International\Geo"
    if (-not (Test-Path $geoPath)) { New-Item -Path $geoPath -Force | Out-Null }
    New-ItemProperty -Path $geoPath -Name 'Nation' -Value $GeoId -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $geoPath -Name 'Name'   -Value 'GB'   -PropertyType String -Force | Out-Null
}
finally {
    Write-Log "Unloading default user registry hive..."
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2
    & reg.exe unload $regRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "reg unload returned exit $LASTEXITCODE - retrying once" -Level WARN
        Start-Sleep -Seconds 3
        & reg.exe unload $regRoot | Out-Null
    }
}

# 4. System accounts / Welcome screen (HKU\.DEFAULT)
Write-Log "Applying en-GB to system accounts (.DEFAULT hive)..."
$sysIntl = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International'
foreach ($name in $intlValues.Keys) {
    New-ItemProperty -Path $sysIntl -Name $name -Value $intlValues[$name] -PropertyType String -Force | Out-Null
}
$sysGeo = 'Registry::HKEY_USERS\.DEFAULT\Control Panel\International\Geo'
if (-not (Test-Path $sysGeo)) { New-Item -Path $sysGeo -Force | Out-Null }
New-ItemProperty -Path $sysGeo -Name 'Nation' -Value $GeoId -PropertyType String -Force | Out-Null
New-ItemProperty -Path $sysGeo -Name 'Name'   -Value 'GB'   -PropertyType String -Force | Out-Null

# 5. Verification
Write-Log ("Get-Culture         : {0}" -f (Get-Culture).Name)
Write-Log ("Get-WinSystemLocale : {0}" -f (Get-WinSystemLocale).Name)
Write-Log ("Get-WinHomeLocation : {0}" -f (Get-WinHomeLocation).HomeLocation)
Write-Log ("Get-TimeZone        : {0}" -f (Get-TimeZone).Id)

Write-Log "Locale configuration complete (Set-WinSystemLocale needs a reboot to fully apply for non-Unicode programs)"
