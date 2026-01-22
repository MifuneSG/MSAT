<# =====================================================================
 Mifune's Sysadmin Toolkit (MST) - v0.2
 Author: Mifune SwordGod
 Purpose: Field-friendly CLI menu for AD + investigation + utilities
 Notes:
 - Tested for Windows PowerShell 5.1 / PowerShell 7.
===================================================================== #>

#region ===== Console & Session Setup =====
[CmdletBinding()]
param(
    [string]$Customer = "UnknownBusiness",
    [string]$OutputRoot = "$PSScriptRoot\Outputs"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = "Mifune's Sysadmin Toolkit"

# Minimal ANSI color helpers
function W([string]$Text, [string]$Color="White"){ Write-Host $Text -ForegroundColor $Color }
function Rule([string]$c='-'){ Write-Host ($c * ($Host.UI.RawUI.WindowSize.Width - 2)) -ForegroundColor DarkGray }

# ASCII banner
$Banner = @"
+-------------------------------------------------------------+
|             MIFUNE'S SYSADMIN TOOLKIT                      |
|     PowerShell Utility Suite for AD - IR - Networking      |
+-------------------------------------------------------------+
"@

# Create a dated working folder + transcript
$SessionStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir = Join-Path $OutputRoot "$($Customer)_$SessionStamp"
New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
$Transcript = Join-Path $OutDir "MST_$($Customer)_$SessionStamp.log"
try { Start-Transcript -Path $Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}

function Stop-MSTTranscript { try { Stop-Transcript | Out-Null } catch {} }
Register-EngineEvent PowerShell.Exiting -Action { Stop-MSTTranscript } | Out-Null
#endregion

#region ===== Common Helpers =====
function Ensure-Module {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        W "Module '$Name' not found. Attempting to import anyway..." Yellow
    }
    try { Import-Module $Name -ErrorAction Stop } catch {
        throw "Required module '$Name' is missing. Please install RSAT or the module."
    }
}

function Export-Table {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$BaseName
    )
    $csv = Join-Path $OutDir "$BaseName.csv"
    $json = Join-Path $OutDir "$BaseName.json"
    $Data | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
    $Data | ConvertTo-Json -Depth 6 | Out-File -FilePath $json -Encoding UTF8
    W "Saved: $csv" Cyan
    W "Saved: $json" DarkCyan
}

function Wait-Key($Prompt="Press ENTER to continue..."){
    Write-Host ""
    Read-Host $Prompt | Out-Null
}

function Ask-Int($Prompt){
    do { $v = Read-Host $Prompt } while (-not ($v -as [int]))
    return [int]$v
}

function Ask-Date($Prompt){
    do { $v = Read-Host $Prompt } while (-not ($v -as [datetime]))
    return [datetime]$v
}
#endregion

#region ===== Active Directory Toolkit =====
function AD-Menu {
    Clear-Host
    W $Banner Green
    W "Mifune's Sysadmin Toolkit - Active Directory" Green
    Rule

Write-Host @'
[1] Inactive users since a date (lastLogonTimestamp)
[2] Users with password age > N days
[3] Server update status (last hotfix, last boot)
[4] Group membership report for a group
[B] Back to Main
'@

    $choice = (Read-Host "Choose").ToUpper()
    switch ($choice) {
        '1' { Find-InactiveADUsers; Wait-Key; AD-Menu }
        '2' { Find-PasswordNotChanged; Wait-Key; AD-Menu }
        '3' { Get-ServerUpdateStatus; Wait-Key; AD-Menu }
        '4' { Get-GroupMembershipReport; Wait-Key; AD-Menu }
        'B' { return }
        Default { AD-Menu }
    }
}

function Find-InactiveADUsers {
    Ensure-Module ActiveDirectory
    $since = Ask-Date "Enter cutoff date (e.g. 7/1/2025 for 'since last school year'):"
    $users = Get-ADUser -Filter * -Properties lastLogonTimestamp, Enabled, whenCreated, Department, Title |
        Select-Object SamAccountName, Name, Enabled, whenCreated,
            @{n='LastLogon'; e={ if ($_.lastLogonTimestamp) { [DateTime]::FromFileTime($_.lastLogonTimestamp) } else { $null } }},
            Department, Title |
        Where-Object { $_.LastLogon -lt $since -or -not $_.LastLogon }
    $users | Format-Table -AutoSize
    Export-Table -Data $users -BaseName "AD_InactiveUsers_Since_$($since.ToString('yyyyMMdd'))"
}

function Find-PasswordNotChanged {
    Ensure-Module ActiveDirectory
    $days = Ask-Int "Enter days since password change (e.g. 365):"
    $cut = (Get-Date).AddDays(-$days)

    $users = Get-ADUser -Filter * -Properties pwdLastSet, PasswordNeverExpires, Enabled |
        Where-Object { $_.Enabled -eq $true } |
        Select-Object SamAccountName, Name, Enabled, PasswordNeverExpires,
            @{n='PwdLastSetDate'; e={ if ($_.pwdLastSet) { [DateTime]::FromFileTime([int64]$_.pwdLastSet) } else { $null } }},
            @{n='DaysSinceChange'; e={ if ($_.pwdLastSet) { (New-TimeSpan -Start ([DateTime]::FromFileTime([int64]$_.pwdLastSet)) -End (Get-Date)).Days } else { $null } }} |
        Where-Object { $_.PasswordNeverExpires -eq $false -and ($_.PwdLastSetDate -lt $cut -or -not $_.PwdLastSetDate) }

    $users | Format-Table -AutoSize
    Export-Table -Data $users -BaseName "AD_PasswordAge_GT_${days}d"
}

function Get-ServerUpdateStatus {
    Ensure-Module ActiveDirectory
    $servers = Get-ADComputer -Filter {OperatingSystem -like "*Server*"} -Properties OperatingSystem, IPv4Address, LastLogonTimestamp

    $report = foreach ($s in $servers) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $s.Name -ErrorAction Stop
            $hotfix = Get-HotFix -ComputerName $s.Name -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
            [pscustomobject]@{
                ComputerName     = $s.Name
                IPv4Address      = $s.IPv4Address
                OperatingSystem  = $s.OperatingSystem
                LastBoot         = $os.LastBootUpTime
                LastHotfixId     = $hotfix.HotFixID
                LastHotfixDate   = $hotfix.InstalledOn
                Reachable        = $true
            }
        } catch {
            [pscustomobject]@{
                ComputerName     = $s.Name
                IPv4Address      = $s.IPv4Address
                OperatingSystem  = $s.OperatingSystem
                LastBoot         = $null
                LastHotfixId     = $null
                LastHotfixDate   = $null
                Reachable        = $false
            }
        }
    }

    $report | Sort-Object Reachable, LastHotfixDate | Format-Table -AutoSize
    Export-Table -Data $report -BaseName "Servers_UpdateStatus"
}

function Get-GroupMembershipReport {
    Ensure-Module ActiveDirectory
    $group = Read-Host "Enter AD group (SAM or DN)"
    $members = Get-ADGroupMember -Identity $group -Recursive -ErrorAction Stop | ForEach-Object {
        if ($_.ObjectClass -eq 'user') {
            Get-ADUser $_ -Properties mail, department, title | Select-Object SamAccountName, Name, mail, department, title
        } elseif ($_.ObjectClass -eq 'group') {
            Get-ADGroup $_ | Select-Object @{n='SamAccountName';e={$_.SamAccountName}}, @{n='Name';e={$_.Name}}, @{n='mail';e={$null}}, @{n='department';e={$null}}, @{n='title';e={'(Group)'}}
        }
    }
    $members | Sort-Object Name | Format-Table -AutoSize
    Export-Table -Data $members -BaseName ("Group_Membership_" + ($group -replace '[\\/:*?"<>|]','_'))
}
#endregion

#region ===== Investigation Toolkit =====
function IR-Menu {
    Clear-Host
    W $Banner Yellow
    W "Mifune's Sysadmin Toolkit - Investigation" Yellow
    Rule

Write-Host @'
[1] Windows Firewall events (last N hours)
[2] Security log: 4624/4625 sign-in summary (last N hours)
[3] Sysmon events (if present) - top Event IDs (last N hours)
[4] Quick triage bundle (processes, services, startups, tasks, listeners)
[5] Network snapshot (routes, DNS, ARP, listening ports)
[B] Back to Main
'@

    $choice = (Read-Host "Choose").ToUpper()
    switch ($choice) {
        '1' { Get-FirewallEvents; Wait-Key; IR-Menu }
        '2' { Get-LogonSummary; Wait-Key; IR-Menu }
        '3' { Get-SysmonSummary; Wait-Key; IR-Menu }
        '4' { Collect-QuickTriage; Wait-Key; IR-Menu }
        '5' { Get-NetworkSnapshot; Wait-Key; IR-Menu }
        'B' { return }
        Default { IR-Menu }
    }
}

function Get-FirewallEvents {
    $hours = Ask-Int "How many hours back? (e.g. 24):"
    $start = (Get-Date).AddHours(-$hours)
    $logName = 'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall'

    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName=$logName; StartTime=$start} -ErrorAction Stop |
            Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
        $ev | Sort-Object TimeCreated -Descending | Format-Table -AutoSize
        Export-Table -Data $ev -BaseName "Events_Firewall_${hours}h"
    } catch {
        W "No firewall event channel or no permissions. Also check: C:\Windows\System32\LogFiles\Firewall\pfirewall.log (if enabled)" Red
    }
}

function Get-LogonSummary {
    $hours = Ask-Int "How many hours back? (e.g. 24):"
    $start = (Get-Date).AddHours(-$hours)
    $ids = 4624,4625
    $ev = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=$ids; StartTime=$start} -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, @{n='Account';e={($_.Properties[5].Value)}}, @{n='Workstation';e={($_.Properties[11].Value)}}, Message

    $summary = $ev | Group-Object Id | ForEach-Object {
        [pscustomobject]@{
            EventId   = $_.Name
            Count     = $_.Count
        }
    }
    W "Summary (by Event ID):" Cyan
    $summary | Format-Table -AutoSize
    Export-Table -Data $ev -BaseName "Security_Logons_${hours}h"
}

function Get-SysmonSummary {
    $hours = Ask-Int "How many hours back? (e.g. 24):"
    $start = (Get-Date).AddHours(-$hours)
    $log = 'Microsoft-Windows-Sysmon/Operational'
    try {
        $ev = Get-WinEvent -FilterHashtable @{LogName=$log; StartTime=$start} -ErrorAction Stop |
            Select-Object TimeCreated, Id, Message
        $top = $ev | Group-Object Id | Sort-Object Count -Descending | Select-Object Name, Count
        W "Top Sysmon Event IDs for last $hours hours:" Cyan
        $top | Format-Table -AutoSize
        Export-Table -Data $ev -BaseName "Sysmon_${hours}h"
    } catch {
        W "Sysmon channel not found. If Sysmon is not deployed here, skip this." Yellow
    }
}

function Collect-QuickTriage {
    W "Collecting quick triage..." Cyan

    $procs = Get-Process | Select-Object Name, Id, CPU, WS, Path, StartTime -ErrorAction SilentlyContinue
    $services = Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName
    $startup  = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User
    $tasks    = schtasks /query /fo CSV /v | ConvertFrom-Csv
    $listen   = Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess

    Export-Table $procs   "IR_Processes"
    Export-Table $services "IR_Services"
    Export-Table $startup  "IR_Startup"
    Export-Table $tasks    "IR_ScheduledTasks"
    Export-Table $listen   "IR_ListeningPorts"

    W "Quick triage saved in $OutDir" Green
}

function Get-NetworkSnapshot {
    W "Gathering network snapshot..." Cyan
    $ipcfg      = ipconfig /all
    $routes     = route print
    $arp        = arp -a
    $dnsTest    = Resolve-DnsName "microsoft.com" -ErrorAction SilentlyContinue
    $listeners  = Get-NetTCPConnection -State Listen | Select-Object LocalAddress, LocalPort, OwningProcess

    Set-Content -Path (Join-Path $OutDir "net_ipconfig.txt") -Value $ipcfg
    Set-Content -Path (Join-Path $OutDir "net_routes.txt") -Value $routes
    Set-Content -Path (Join-Path $OutDir "net_arp.txt") -Value $arp
    $dnsTest | Out-File -Encoding UTF8 -FilePath (Join-Path $OutDir "net_dns_test.txt")
    Export-Table -Data $listeners -BaseName "net_listeners"

    W "Network snapshot saved in $OutDir" Green
}
#endregion

#region ===== Networking & Inventory (extra handy stuff) =====
function NetInv-Menu {
    Clear-Host
    W $Banner Cyan
    W "Mifune's Sysadmin Toolkit - Networking and Inventory" Cyan
    Rule

Write-Host @'
[1] Ping sweep (quick) of a /24
[2] Host inventory (OS, CPU, RAM, BIOS) via CIM (single host)
[B] Back to Main
'@

    $choice = (Read-Host "Choose").ToUpper()
    switch ($choice) {
        '1' { Invoke-PingSweep24; Wait-Key; NetInv-Menu }
        '2' { Get-HostInventory; Wait-Key; NetInv-Menu }
        'B' { return }
        Default { NetInv-Menu }
    }
}

function Invoke-PingSweep24 {
    $base = Read-Host "Enter base /24 (e.g. 192.168.1)"
    $live = foreach ($i in 1..254) {
        $ip = "$base.$i"
        if (Test-Connection -Count 1 -Quiet -TimeoutSeconds 1 $ip) { [pscustomobject]@{IP=$ip; Reachable=$true} }
    }
    $live | Format-Table -AutoSize
    Export-Table -Data $live -BaseName "PingSweep_${base}_24"
}

function Get-HostInventory {
    $TargetHost = Read-Host "Enter hostname or IP"
    try {
        $os   = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $TargetHost -ErrorAction Stop
        $cpu  = Get-CimInstance -ClassName Win32_Processor -ComputerName $TargetHost
        $mem  = Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $TargetHost
        $bios = Get-CimInstance -ClassName Win32_BIOS -ComputerName $TargetHost

        $obj = [pscustomobject]@{
            ComputerName = $TargetHost
            OS           = $os.Caption
            OSVersion    = $os.Version
            LastBoot     = $os.LastBootUpTime
            CPU          = ($cpu.Name -join ', ')
            TotalRAMGB   = [math]::Round($mem.TotalPhysicalMemory/1GB,2)
            BIOS         = $bios.SMBIOSBIOSVersion
            Serial       = $bios.SerialNumber
        }
        $obj | Format-List
        Export-Table -Data $obj -BaseName "HostInventory_$TargetHost"
    } catch {
        W "Failed to query $TargetHost - permissions/firewall?" Red
    }
}
#endregion

#region ===== Host Diagnostics =====
function HostDiag-Menu {
    Clear-Host
    W $Banner White
    W "Mifune's Sysadmin Toolkit - Host Diagnostics" White
    Rule

Write-Host @'
[1] Local Administrators audit
[2] RSOP (Group Policy) summary
[3] BitLocker status (all volumes)
[4] Disk health (SMART/drive info)
[5] Export Wi-Fi profiles (XML)
[B] Back to Main
'@

    $choice = (Read-Host "Choose").ToUpper()
    switch ($choice) {
        '1' { Get-LocalAdministrators; Wait-Key; HostDiag-Menu }
        '2' { Get-RsopSummary;        Wait-Key; HostDiag-Menu }
        '3' { Get-BitLockerStatus;    Wait-Key; HostDiag-Menu }
        '4' { Get-DiskHealth;         Wait-Key; HostDiag-Menu }
        '5' { Export-WiFiProfiles;    Wait-Key; HostDiag-Menu }
        'B' { return }
        Default { HostDiag-Menu }
    }
}

function Get-LocalAdministrators {
    try {
        $admins = Get-LocalGroupMember -Group 'Administrators' |
            Select-Object Name, ObjectClass, PrincipalSource
    } catch {
        $admins = (net localgroup administrators) -match '^\S' | ForEach-Object {
            [pscustomobject]@{ Name=$_; ObjectClass='Unknown'; PrincipalSource='net.exe' }
        }
    }
    $admins | Format-Table -AutoSize
    Export-Table -Data $admins -BaseName "Host_LocalAdministrators"
}

function Get-RsopSummary {
    $file = Join-Path $OutDir "RSOP_$($env:COMPUTERNAME).txt"
    gpresult /r /scope computer | Out-File -FilePath $file -Encoding UTF8
    gpresult /r /scope user     | Out-File -FilePath $file -Append -Encoding UTF8
    Write-Host "Saved: $file"
}

function Get-BitLockerStatus {
    try { Import-Module BitLocker -ErrorAction Stop } catch {}
    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object `
        MountPoint, VolumeType, ProtectionStatus, EncryptionMethod,
        @{n='CapacityGB';e={[math]::Round($_.Capacity/1GB,2)}},
        @{n='Encryption%';e={$_.EncryptionPercentage}}
    if(-not $vols){ Write-Host "BitLocker not available or no protected volumes." }
    $vols | Format-Table -AutoSize
    Export-Table -Data $vols -BaseName "Host_BitLockerStatus"
}

function Get-DiskHealth {
    $disks = Get-CimInstance Win32_DiskDrive | Select-Object `
        Index, Model, SerialNumber, InterfaceType, FirmwareRevision,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}},
        Status
    $disks | Format-Table -AutoSize
    Export-Table -Data $disks -BaseName "Host_DiskHealth"
}

function Export-WiFiProfiles {
    $dest = Join-Path $OutDir "WiFiProfiles"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    netsh wlan export profile folder="$dest" key=clear | Out-Null
    $ssid = (netsh wlan show interfaces) -match '^\s*SSID\s*:\s*(.+)$' |
            ForEach-Object { ($_ -split ':',2)[1].Trim() } | Select-Object -First 1
    Write-Host "Exported Wi-Fi XML profiles to: $dest"
    if($ssid){ Write-Host "Current SSID: $ssid" }
}
#endregion

#region ===== Utilities =====
function Utils-Menu {
    Clear-Host
    W $Banner Magenta
    W "Mifune's Sysadmin Toolkit - Utilities" Magenta
    Rule

Write-Host @'
[1] Start transcript to custom file
[2] Open output folder
[3] Check admin/elevation
[B] Back to Main
'@

    $choice = (Read-Host "Choose").ToUpper()
    switch ($choice) {
        '1' { $p = Read-Host "Enter full path for transcript"; try { Start-Transcript -Path $p -Append } catch { W $_ Red }; Wait-Key; Utils-Menu }
        '2' { Invoke-Item $OutDir; Utils-Menu }
        '3' { Test-Admin; Wait-Key; Utils-Menu }
        'B' { return }
        Default { Utils-Menu }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        W "Elevated: YES" Green
    } else {
        W "Elevated: NO - some features may fail. Run PowerShell as Administrator." Yellow
    }
}
#endregion

#region ===== Main Menu =====
function Show-MainMenu {
    while ($true) {
        Clear-Host
        W $Banner White
        W "Title: Mifune's Sysadmin Toolkit" White
        W "Customer: $Customer" DarkGray
        W "Output:   $OutDir" DarkGray
        Rule

Write-Host @'
[1] Active Directory Toolkit
[2] Investigation Toolkit
[3] Networking and Inventory
[4] Utilities
[5] Host Diagnostics
[Q] Quit
'@

        $sel = (Read-Host "Choose").ToUpper()
        switch ($sel) {
            '1' { AD-Menu }
            '2' { IR-Menu }
            '3' { NetInv-Menu }
            '4' { Utils-Menu }
            '5' { HostDiag-Menu }
            'Q' { break }
            Default { }
        }
    }
    Stop-MSTTranscript
}
#endregion

# Kickoff
Show-MainMenu
