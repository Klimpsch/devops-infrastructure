# Windows Server Hardening Script (2019 / 2022 / 2025)
# Run as Administrator:
#     powershell -ExecutionPolicy Bypass -File .\Windows-Server-Hardening-script.ps1
#
# Applies a basic CIS-style baseline: Defender, ASR rules, firewall,
# SMB / RDP / credential hardening, name-resolution lockdown, account +
# audit policy, PowerShell logging, service pruning, UAC.

#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Section { param($t) Write-Host "`n========== $t ==========" -ForegroundColor Cyan }
function Info    { param($t) Write-Host "[INFO]  $t" -ForegroundColor Cyan }
function Ok      { param($t) Write-Host "[OK]    $t" -ForegroundColor Green }
function Warn    { param($t) Write-Host "[WARN]  $t" -ForegroundColor Yellow }

$logDir = 'C:\Windows\Temp'
$log    = Join-Path $logDir ("windows_hardening_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $log -Append | Out-Null
Info "Logging to $log"


Section 'Windows Update (scan only)'
try {
    (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    Ok 'Update scan triggered — install via WSUS / Windows Update UI'
} catch { Warn "Update scan skipped: $($_.Exception.Message)" }


Section 'Microsoft Defender'
try {
    Set-MpPreference -DisableRealtimeMonitoring $false
    Set-MpPreference -MAPSReporting Advanced
    Set-MpPreference -SubmitSamplesConsent SendSafeSamples
    Set-MpPreference -PUAProtection Enabled
    Set-MpPreference -CloudBlockLevel High
    Set-MpPreference -CloudExtendedTimeout 50
    Set-MpPreference -EnableControlledFolderAccess Enabled
    Set-MpPreference -EnableNetworkProtection Enabled
    Ok 'Defender real-time + cloud + PUA + CFA enabled'
} catch { Warn "Defender config partial: $($_.Exception.Message)" }


Section 'Attack Surface Reduction rules'
# GUIDs from learn.microsoft.com/defender-endpoint/attack-surface-reduction-rules-reference
$asr = @{
    'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550' = 'Block executable content from email / webmail'
    'D4F940AB-401B-4EFC-AADC-AD5F3C50688A' = 'Block Office apps from creating child processes'
    '3B576869-A4EC-4529-8536-B80A7769E899' = 'Block Office apps from creating executable content'
    '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84' = 'Block Office apps from injecting into other processes'
    'D3E037E1-3EB8-44C8-A917-57927947596D' = 'Block JS/VBScript from launching downloaded executables'
    '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC' = 'Block obfuscated scripts'
    '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' = 'Block Win32 API calls from Office macros'
    'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4' = 'Block untrusted/unsigned USB processes'
    'E6DB77E5-3DF2-4CF1-B95A-636979351E5B' = 'Block persistence via WMI event subscription'
    '26190899-1602-49E8-8B27-EB1D0A1CE869' = 'Block Office comms apps from creating child processes'
    '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2' = 'Block credential stealing from LSASS'
}
foreach ($id in $asr.Keys) {
    try {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $id -AttackSurfaceReductionRules_Actions Enabled -ErrorAction Stop
        Info "ASR on: $($asr[$id])"
    } catch { Warn "ASR $id not applied: $($_.Exception.Message)" }
}
Ok 'ASR rules configured'


Section 'Firewall'
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
Set-NetFirewallProfile -Profile Public,Private        -DefaultInboundAction Block -DefaultOutboundAction Allow
Set-NetFirewallProfile -Profile Domain                -DefaultInboundAction Block -DefaultOutboundAction Allow
Set-NetFirewallProfile -Profile Domain,Public,Private `
    -LogFileName '%SystemRoot%\System32\LogFiles\Firewall\pfirewall.log' `
    -LogMaxSizeKilobytes 16384 -LogAllowed False -LogBlocked True -LogIgnored False
# Disable inbound ICMP echo on Public (keep on Domain/Private for diagnostics)
Get-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMPv4-In)' -ErrorAction SilentlyContinue |
    Where-Object Profile -match 'Public' | Set-NetFirewallRule -Enabled False
Ok 'Firewall enabled on all profiles, dropped packets logged'


Section 'SMB hardening'
try {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
    Set-SmbServerConfiguration -EnableSMB2Protocol $true  -Force
    Set-SmbServerConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force
    Set-SmbClientConfiguration -RequireSecuritySignature $true -EnableSecuritySignature $true -Force
    Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Ok 'SMBv1 disabled, signing required'
} catch { Warn "SMB hardening partial: $($_.Exception.Message)" }


Section 'RDP hardening'
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
Set-ItemProperty -Path $ts -Name 'fDenyTSConnections' -Value 0 -Type DWord
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name 'UserAuthentication' -Value 1 -Type DWord   # NLA
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name 'SecurityLayer'     -Value 2 -Type DWord   # TLS
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name 'MinEncryptionLevel' -Value 3 -Type DWord  # High (128-bit)
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name 'MaxIdleTime'       -Value 900000 -Type DWord  # 15 min
Set-ItemProperty -Path "$ts\WinStations\RDP-Tcp" -Name 'MaxDisconnectionTime' -Value 60000 -Type DWord
Ok 'RDP: NLA required, TLS, 128-bit, 15m idle timeout'


Section 'Credential protection'
# Disable WDigest (prevents cleartext cred caching in LSASS)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' `
    -Name 'UseLogonCredential' -Value 0 -Type DWord
# LSA protection (RunAsPPL)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL' -Value 1 -Type DWord
# NTLMv2 only; refuse LM/NTLMv1
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Value 5 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'NoLMHash' -Value 1 -Type DWord
# Disable storage of cleartext passwords
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'NtlmMinClientSec' -Value 0x20080000 -Type DWord
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -Name 'NtlmMinServerSec' -Value 0x20080000 -Type DWord
# UAC to highest (always notify, secure desktop, admin approval mode)
$ua = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty -Path $ua -Name 'EnableLUA'            -Value 1 -Type DWord
Set-ItemProperty -Path $ua -Name 'ConsentPromptBehaviorAdmin' -Value 2 -Type DWord
Set-ItemProperty -Path $ua -Name 'PromptOnSecureDesktop'     -Value 1 -Type DWord
Ok 'WDigest off, LSA PPL on, NTLMv2-only, UAC on'


Section 'Name resolution lockdown'
# LLMNR off
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' `
    -Name 'EnableMulticast' -Value 0 -Type DWord
# NetBIOS over TCP/IP off for every interface
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' |
    ForEach-Object {
        Set-ItemProperty -Path $_.PSPath -Name 'NetbiosOptions' -Value 2 -Type DWord -ErrorAction SilentlyContinue
    }
# WPAD off
Set-Service -Name WinHttpAutoProxySvc -StartupType Disabled -ErrorAction SilentlyContinue
# mDNS off (Server 2022+)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' `
    -Name 'EnableMDNS' -Value 0 -Type DWord -ErrorAction SilentlyContinue
Ok 'LLMNR / NBT-NS / mDNS / WPAD disabled'


Section 'Account policy'
& net accounts /minpwlen:14 /maxpwage:90 /minpwage:1 /uniquepw:24 | Out-Null
& net accounts /lockoutthreshold:5 /lockoutduration:30 /lockoutwindow:30 | Out-Null
# Disable Guest
try { Disable-LocalUser -Name 'Guest' -ErrorAction Stop; Info 'Guest disabled' } catch { Info 'Guest already disabled or absent' }
Ok 'Password + lockout policy applied, Guest disabled'


Section 'Audit policy'
$cats = @(
    'Logon','Logoff','Account Lockout','Special Logon',
    'Credential Validation','Kerberos Authentication Service','Kerberos Service Ticket Operations',
    'User Account Management','Computer Account Management','Security Group Management',
    'Process Creation','Sensitive Privilege Use',
    'Audit Policy Change','Authentication Policy Change','Authorization Policy Change',
    'Security State Change','Security System Extension','System Integrity',
    'Removable Storage','File Share','Detailed File Share'
)
foreach ($c in $cats) {
    & auditpol /set /subcategory:"$c" /success:enable /failure:enable | Out-Null
}
# Include command line in process creation events
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' `
    -Name 'ProcessCreationIncludeCmdLine_Enabled' -Value 1 -Type DWord -ErrorAction SilentlyContinue
# Enlarge Security log (1 GB)
& wevtutil sl Security /ms:1073741824 | Out-Null
Ok 'Audit subcategories configured, Security log sized to 1 GB'


Section 'PowerShell logging'
$pwsh = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
New-Item -Path "$pwsh\ScriptBlockLogging" -Force | Out-Null
New-Item -Path "$pwsh\ModuleLogging"      -Force | Out-Null
New-Item -Path "$pwsh\Transcription"      -Force | Out-Null
Set-ItemProperty -Path "$pwsh\ScriptBlockLogging" -Name 'EnableScriptBlockLogging' -Value 1 -Type DWord
Set-ItemProperty -Path "$pwsh\ModuleLogging"      -Name 'EnableModuleLogging'      -Value 1 -Type DWord
New-Item -Path "$pwsh\ModuleLogging\ModuleNames" -Force | Out-Null
Set-ItemProperty -Path "$pwsh\ModuleLogging\ModuleNames" -Name '*' -Value '*'
Set-ItemProperty -Path "$pwsh\Transcription" -Name 'EnableTranscripting' -Value 1 -Type DWord
Set-ItemProperty -Path "$pwsh\Transcription" -Name 'OutputDirectory'     -Value 'C:\PSTranscripts'
Set-ItemProperty -Path "$pwsh\Transcription" -Name 'EnableInvocationHeader' -Value 1 -Type DWord
New-Item -ItemType Directory -Force -Path 'C:\PSTranscripts' | Out-Null
Ok 'Script-block, module, and transcription logging enabled'


Section 'Autoplay / Autorun'
$ap = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
New-Item -Path $ap -Force | Out-Null
Set-ItemProperty -Path $ap -Name 'NoDriveTypeAutoRun' -Value 0xFF -Type DWord
Set-ItemProperty -Path $ap -Name 'NoAutorun'          -Value 1    -Type DWord
Ok 'AutoPlay + AutoRun disabled on all drives'


Section 'Remove legacy Windows features'
$remove = 'SMB1Protocol','MicrosoftWindowsPowerShellV2','MicrosoftWindowsPowerShellV2Root',
          'TelnetClient','TFTP','WindowsMediaPlayer','Internet-Explorer-Optional-amd64'
foreach ($f in $remove) {
    try {
        $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop
        if ($s.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart -ErrorAction Stop | Out-Null
            Info "Removed: $f"
        }
    } catch { }  # feature not present on this SKU
}
Ok 'Legacy features pruned'


Section 'Disable risky services'
$svc = 'XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc',
       'Fax','Spooler','WebClient','RemoteRegistry','SharedAccess',
       'lfsvc','MapsBroker','WMPNetworkSvc','SSDPSRV','upnphost','icssvc'
foreach ($s in $svc) {
    $o = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($o) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $s -StartupType Disabled -ErrorAction SilentlyContinue
        Info "Disabled: $s"
    }
}
Warn 'Spooler disabled — re-enable if this host needs to print (PrintNightmare risk otherwise)'
Ok 'Attack-surface services disabled'


Section 'Network stack hardening'
$tcp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
Set-ItemProperty -Path $tcp -Name 'DisableIPSourceRouting'     -Value 2 -Type DWord
Set-ItemProperty -Path $tcp -Name 'EnableICMPRedirect'         -Value 0 -Type DWord
Set-ItemProperty -Path $tcp -Name 'KeepAliveTime'              -Value 300000 -Type DWord
Set-ItemProperty -Path $tcp -Name 'PerformRouterDiscovery'     -Value 0 -Type DWord
Set-ItemProperty -Path $tcp -Name 'SynAttackProtect'           -Value 1 -Type DWord -ErrorAction SilentlyContinue
# IPv6 source routing off
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
    -Name 'DisableIPSourceRouting' -Value 2 -Type DWord
Ok 'TCP/IP stack hardened against redirects + source routing'


Section 'Time sync'
& w32tm /config /manualpeerlist:'time.windows.com,0x9 pool.ntp.org,0x9' /syncfromflags:manual /reliable:yes /update | Out-Null
Restart-Service w32time -ErrorAction SilentlyContinue
Ok 'w32time pointed at time.windows.com + pool.ntp.org'


Section 'SmartScreen + Installer restrictions'
$ss = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
New-Item -Path $ss -Force | Out-Null
Set-ItemProperty -Path $ss -Name 'EnableSmartScreen' -Value 1 -Type DWord
Set-ItemProperty -Path $ss -Name 'ShellSmartScreenLevel' -Value 'Block' -Type String
# Block non-admins from installing MSI elevated
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' `
    -Name 'AlwaysInstallElevated' -Value 0 -Type DWord -ErrorAction SilentlyContinue
Ok 'SmartScreen enforcing, elevated MSI install blocked for non-admins'


Section 'Hardening complete'
Write-Host ''
Write-Host '  + Defender real-time, cloud, PUA, CFA' -ForegroundColor Green
Write-Host '  + Attack Surface Reduction rules applied' -ForegroundColor Green
Write-Host '  + Firewall on all profiles, drops logged' -ForegroundColor Green
Write-Host '  + SMBv1 off, SMB signing required' -ForegroundColor Green
Write-Host '  + RDP: NLA + TLS + 128-bit + idle timeout' -ForegroundColor Green
Write-Host '  + WDigest off, LSA PPL on, NTLMv2 only, UAC high' -ForegroundColor Green
Write-Host '  + LLMNR / NBT-NS / mDNS / WPAD disabled' -ForegroundColor Green
Write-Host '  + Password + lockout policy applied, Guest off' -ForegroundColor Green
Write-Host '  + Audit subcategories on, Security log 1 GB' -ForegroundColor Green
Write-Host '  + PowerShell script-block + transcription logging' -ForegroundColor Green
Write-Host '  + Autoplay / Autorun disabled' -ForegroundColor Green
Write-Host '  + Legacy features removed (SMB1, PSv2, Telnet, TFTP)' -ForegroundColor Green
Write-Host '  + Attack-surface services disabled' -ForegroundColor Green
Write-Host '  + TCP/IP hardened against redirects + source routing' -ForegroundColor Green
Write-Host '  + Time sync configured' -ForegroundColor Green
Write-Host '  + SmartScreen enforcing' -ForegroundColor Green
Write-Host ''
Warn 'Reboot required for LSA PPL, SMB1 removal, and audit policy to fully take effect'
Info "Full transcript: $log"
Stop-Transcript | Out-Null
