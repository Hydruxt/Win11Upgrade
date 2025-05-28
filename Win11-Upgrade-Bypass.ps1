<#
.SYNOPSIS
    Silent Windows-11 in-place upgrade on unsupported hardware
    with automatic resume after the mandatory language-change reboot.

.NOTES
    - Deploy/run from RMM as SYSTEM
    - Exit-codes:
        0      = Upgrade launched (or completed in quiet mode)
        3010   = Reboot scheduled via Windows Restart-Computer
        other  = Windows Setup return code (failure)
#>

# ------------ configuration ------------
$IsoUrl      = 'https://software-download.microsoft.com/sg/Win11_24H2_EnglishInternational_x64.iso'
$TempRoot    = "$env:SystemDrive\Temp\Win11Upgrade"
$Unattend    = "$TempRoot\Upgrade.xml"
$IsoPath     = "$TempRoot\win11.iso"
$LabConfig   = 'HKLM:\SYSTEM\Setup\LabConfig'
$MoSetup     = 'HKLM:\SYSTEM\Setup\MoSetup'
$SetupScript = "$env:SystemRoot\Setup\Scripts"
$TaskName    = 'Win11Upgrade-Resume'
# ---------------------------------------

function Write-Log { param([string]$Msg) ; Write-Host "$(Get-Date -f s)  $Msg" }
function Ensure-Dir { param($Path) ; if (-not (Test-Path $Path)) { New-Item $Path -ItemType Directory -Force | Out-Null } }

Ensure-Dir $TempRoot

# 0. Remove resume task if we were launched by it
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Log "Removed scheduled resume task."
}

# 1. Language check and schedule CHKDSK
$NeedReboot = $false
try {
    $sysLang = (Get-Culture).Name
    if ($sysLang -ne 'en-US') {
        Write-Log "System UI language is $sysLang. Switching to en-US."
        Install-Language en-US -CopyToSettings -Force
        Set-WinUILanguageOverride -Language en-US
        Set-WinSystemLocale       -SystemLocale en-US
        $NeedReboot = $true
    }
} catch { Write-Log "WARNING: Language change failed - $_" }

if ($NeedReboot) {
    # Register one-shot resume task
    $psSelf = '"' + $PSCommandPath + '"'
    $action  = New-ScheduledTaskAction  -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $psSelf"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -RunLevel Highest -User 'SYSTEM' -Force | Out-Null

    # Mark C: dirty so CHKDSK /F runs before Windows loads
    try {
        Write-Log "Scheduling CHKDSK /F via fsutil dirty set C:."
        fsutil dirty set C: | Out-Null
    } catch { Write-Log "WARNING: Could not set dirty bit - $_" }

    Write-Log "Rebooting now. Script will resume afterwards."
    Restart-Computer -Force
    exit 3010
}

# 2. Download ISO if missing
if (-not (Test-Path $IsoPath)) {
    Write-Log "Downloading ISO ..."
    Invoke-WebRequest $IsoUrl -OutFile $IsoPath -UseBasicParsing
}

# 3. Registry bypass keys
Write-Log "Writing LabConfig and MoSetup keys ..."
Ensure-Dir (Split-Path $LabConfig)
foreach ($name in 'BypassTPMCheck','BypassSecureBootCheck','BypassCPUCheck','BypassRAMCheck','BypassStorageCheck','BypassNetworkCheck') {
    New-ItemProperty $LabConfig -Name $name -Value 1 -PropertyType DWord -Force | Out-Null
}
Ensure-Dir (Split-Path $MoSetup)
New-ItemProperty $MoSetup -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Value 1 -PropertyType DWord -Force | Out-Null

# 4. Unattend file to suppress all UI
@'
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UpgradeData>
        <Upgrade>true</Upgrade>
        <WillShowUI>Never</WillShowUI>
      </UpgradeData>
    </component>
  </settings>
</unattend>
'@ | Out-File $Unattend -Encoding ASCII -Force

# 5. Mount ISO and launch Setup
Write-Log "Mounting ISO ..."
$mount  = Mount-DiskImage -ImagePath $IsoPath -PassThru
$volume = ($mount | Get-Volume).DriveLetter + ':'
$setup  = "$volume\setup.exe"

$setupArgs = @(
    '/quiet','/noreboot',
    '/eula','accept',
    '/dynamicupdate','disable',
    '/Compat','IgnoreWarning',
    "/Unattend:`"$Unattend`""
)

Write-Log "Starting Windows Setup ..."
Start-Process $setup -ArgumentList $setupArgs -Wait
$exit = $LASTEXITCODE
Write-Log "Setup finished with exit code $exit"

# 6. SetupComplete cleanup
Ensure-Dir $SetupScript
@"
@echo off
rd /s /q "$TempRoot" >nul 2>&1
reg delete "$LabConfig" /f >nul 2>&1
reg delete "$MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /f >nul 2>&1
schtasks /Delete /TN "$TaskName" /F >nul 2>&1
exit /b 0
"@ | Out-File "$SetupScript\SetupComplete.cmd" -Encoding ASCII -Force

exit $exit
