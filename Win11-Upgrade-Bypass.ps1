# ========== CONFIGURATION ==========
$ISOName       = "Win11.iso"
$TempISOPath   = "c:\temp\$ISOName"
$CDNUrl        = "https://software.download.prss.microsoft.com/dbazure/Win11_24H2_English_x64.iso?t=553d31f8-aff2-4496-9eba-e0b9562e7158&P1=1748329687&P2=601&P3=2&P4=bi6LW%2bGXrgCECfNyekGNvyLZty7M7nkefd52gYeaSodDXcvOKvlNP2Vdcq6b7Ge4KKYZffNdBTPeMoHNhSKB8HCwLkgLnd5zajkXrN4PdzVQQUmZCPXb65hZs5uUmGPs3g7e0efLqI2z3iGTShnHO%2f6kKN7sORhvlpcnzr6vIBdz2zSUWyBCeT1M%2fj%2fRda3BNpiSoTdkRYt9i2K%2bVCvI%2bubJu%2fKDhLciwAP9aK89zagNiPXl3lZJF5oDoduy9zvTqUntaNCrKw%2fQKcDLH1MkpUweBe%2bcYlLUQO%2b6d8KMhnfECRgu18Q3Hp5oRBfWHUUqYUEAUixnocetaFnxOpsNzw%3d%3d"
$ExpectedHash  = "B56B911BF18A2CEAEB3904D87E7C770BDF92D3099599D61AC2497B91BF190B11"  # SHA256 (optional)
$LogPath       = "C:\Temp\logs"
$SetupArgs     = "/auto upgrade /dynamicupdate disable /eula accept /product server"
# ===================================

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$ts] [$Level] $Message"
    Write-Host $logLine

    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path "$LogPath\Upgrade.log" -Value $logLine
}

function Test-IsMeteredConnection {
    $connections = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -ne "Disconnected" }

    if (-not $connections) {
        Write-Log "No active network connections found. Assuming safe to proceed." "WARN"
        return $false
    }

    foreach ($conn in $connections) {
        $cost = $conn.ConnectionCost

        if ([string]::IsNullOrWhiteSpace($cost)) {
            Write-Log "No ConnectionCost info for '$($conn.InterfaceAlias)'. Assuming unrestricted." "WARN"
            continue
        }

        if ($cost -in @("Metered", "OverDataLimit", "ApproachingDataLimit")) {
            Write-Log "Metered connection detected on '$($conn.InterfaceAlias)' - upgrade aborted." "ERROR"
            return $true
        }
    }

    return $false
}

function Set-BypassRegistry {
    Write-Log "Setting LabConfig bypass registry keys..."
    try {
        New-Item -Path "HKLM:\SYSTEM\Setup\LabConfig" -Force | Out-Null
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassTPMCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassSecureBootCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassCPUCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassRAMCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassStorageCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassDiskCheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassWGACheck" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassAppraiser" -Type DWord -Value 1
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -Name "ImageState" -Value "IMAGE_STATE_COMPLETE"
        Write-Log "Bypass keys successfully set." "SUCCESS"
    }
    catch {
        Write-Log "Failed to set bypass keys: $_" "ERROR"
        exit 1
    }
}

function Validate-ISO {
    if (-not (Test-Path $TempISOPath)) { return $false }

    if ($ExpectedHash -ne "") {
        Write-Log "Validating ISO hash..."
        $actualHash = (Get-FileHash -Path $TempISOPath -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedHash) {
            Write-Log "ISO hash mismatch. Expected $ExpectedHash, got $actualHash" "ERROR"
            Remove-Item $TempISOPath -Force
            return $false
        }
        Write-Log "ISO hash validated successfully." "SUCCESS"
    }

    return $true
}

function Download-ISO {
    Write-Log "Attempting to download ISO from $CDNUrl..."
    try {
        Invoke-WebRequest -Uri $CDNUrl -OutFile $TempISOPath -UseBasicParsing
        Write-Log "ISO downloaded to $TempISOPath" "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to download ISO: $_" "ERROR"
        return $false
    }
}

function Mount-And-Upgrade {
    Write-Log "Mounting ISO..."
    try {
        Mount-DiskImage -ImagePath $TempISOPath -ErrorAction Stop
        $volume = (Get-DiskImage -ImagePath $TempISOPath | Get-Volume).DriveLetter + ":"
    }
    catch {
        Write-Log "Failed to mount ISO: $_" "ERROR"
        exit 1
    }

    $setup = Join-Path $volume "setup.exe"
    if (-not (Test-Path $setup)) {
        Write-Log "setup.exe not found in mounted ISO!" "ERROR"
        exit 1
    }

    Write-Log "Launching Windows 11 setup..."
    Start-Process -FilePath $setup -ArgumentList $SetupArgs -WorkingDirectory $volume -Wait
    Write-Log "Setup launched successfully." "SUCCESS"
}

function Match-Language-to-ISO {
    $currentDisplayLang = Get-WinUILanguageOverride
    $installedLangs = Get-InstalledLanguage

    if ($installedLangs.Language -contains 'en-US' -and $currentDisplayLang -eq 'en-US') {
     Write-Host "en-US is already installed and set as the display language. No action needed."
        } else {
        Install-Language en-US -CopyToSettings
        Set-WinUILanguageOverride -Language en-US
        Set-WinUserLanguageList -LanguageList (New-WinUserLanguageList -Language en-US) -Force
        Write-Host "en-US installed and set as the display language. Reboot required."
    }
}


# === SCRIPT ENTRY POINT ===

function Test-IsElevated {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7+ compatible
        $adminCheck = [System.Environment]::UserInteractive -and `
                      ([System.Security.Principal.WindowsPrincipal] `
                          [System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
                          [System.Security.Principal.WindowsBuiltInRole]::Administrator)
        return $adminCheck
    } else {
        # Windows PowerShell 5.1
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

if (-not (Test-IsElevated)) {
    Write-Host "[ERROR] Script must be run as Administrator."
    exit 1
}

Write-Log "==== Windows 11 Upgrade Started ===="

# Try existing local ISO
#if (Validate-ISO) {
#    Write-Log "Valid ISO already present." "INFO"
#
#}

# Download from web
if (-not (Test-IsMeteredConnection)) {
    if (-not (Download-ISO)) {
        Write-Log "Download failed. Aborting upgrade." "ERROR"
        exit 1
    }
}
else {
    Write-Log "No ISO available and metered connection detected. Aborting." "ERROR"
    exit 1
}

Match-Language-to-ISO
Set-BypassRegistry
Mount-And-Upgrade