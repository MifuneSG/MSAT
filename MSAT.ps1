<#
    Mifune's Sysadmin Toolkit (MSAT)
    Field CLI for MSP work: Active Directory, on-prem investigation, endpoint
    health, network/inventory, and Microsoft 365 / Entra read-outs.

    Windows PowerShell 5.1 and PowerShell 7+. Single file, no install.
    Results are written per session as CSV + JSON, with an optional HTML report.

        .\MSAT.ps1 -Customer "Acme Corp"
#>

[CmdletBinding()]
param(
    [string]$Customer = 'UnknownClient',
    [string]$OutputRoot
)

#region Session state

if (-not $OutputRoot) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $OutputRoot = Join-Path $root 'Outputs'
}

$script:Session = [pscustomobject]@{
    Customer = $Customer
    Stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    OutDir   = $null
    Started  = Get-Date
    Sections = New-Object System.Collections.Generic.List[object]
    Graph    = $false
}

#endregion

#region Console output helpers

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { $Host.UI.RawUI.WindowTitle = "Mifune's Sysadmin Toolkit" } catch {}

function Write-Head { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }
function Write-Info { param([string]$Text) Write-Host $Text }
function Write-Good { param([string]$Text) Write-Host $Text -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host $Text -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text) Write-Host $Text -ForegroundColor Red }

function Write-Rule {
    param([ConsoleColor]$Color = 'DarkGray')
    $w = 64
    try { if ($Host.UI.RawUI.WindowSize.Width -gt 12) { $w = $Host.UI.RawUI.WindowSize.Width - 1 } } catch {}
    Write-Host ('─' * $w) -ForegroundColor $Color
}

$script:Logo = @(
    ' __  __  ____    _   _____ '
    '|  \/  |/ ___|  / \ |_   _|'
    '| |\/| |\___ \ / _ \  | |  '
    '| |  | | ___) / ___ \ | |  '
    '|_|  |_|____/_/   \_\ |_|  '
)
$script:BrandBorder = 'DarkCyan'
$script:BrandInk    = 'Cyan'
$script:BladeLen    = 18
$script:Sword = @(
    '            _'
    ' _         | |'
    '| | _______| |' + ('-' * $script:BladeLen) + '\'
    '|:-)_______|==[]' + ('=' * ($script:BladeLen - 1)) + '>'
    '|_|        | |' + ('-' * $script:BladeLen) + '/'
    '           |_|'
)

function Show-Brand {
    $ink   = $script:BrandInk
    $steel = 'Gray'
    $brass = 'DarkYellow'
    foreach ($row in $script:Logo) { Write-Host ('  ' + $row) -ForegroundColor $ink }
    foreach ($line in $script:Sword) {
        $s = '  ' + $line
        if ($s.Length -le 6) { Write-Host $s -ForegroundColor $steel; continue }
        Write-Host $s.Substring(0, 6) -ForegroundColor $brass -NoNewline
        Write-Host $s.Substring(6) -ForegroundColor $steel
    }
    Write-Host "  MIFUNE'S SYSADMIN TOOLKIT" -ForegroundColor DarkGray
}

function Write-MetaRow {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor)
    Write-Host ('   ' + $Label + '  ') -ForegroundColor DarkGray -NoNewline
    Write-Host '▸ ' -ForegroundColor $script:BrandBorder -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Show-Meta {
    Write-Host ''
    Write-MetaRow 'CLIENT ' $script:Session.Customer 'Yellow'
    Write-MetaRow 'SESSION' $script:Session.Stamp 'White'
    if ($script:Session.OutDir) { Write-MetaRow 'OUTPUT ' $script:Session.OutDir 'DarkGray' }
}

function Show-Banner {
    param([string]$Subtitle, [ConsoleColor]$Color = 'White')
    Clear-Host
    Write-Host ''
    Show-Brand
    Show-Meta
    if ($Subtitle) {
        Write-Host ''
        Write-Host '  ▌ ' -ForegroundColor $Color -NoNewline
        Write-Host $Subtitle.ToUpper() -ForegroundColor $Color
    }
    Write-Rule
}

#endregion

#region Input helpers

function Wait-Key {
    Write-Host ''
    Read-Host '  Press ENTER to continue' | Out-Null
}

function Read-Int {
    param([string]$Prompt, [int]$Default)
    $hasDefault = $PSBoundParameters.ContainsKey('Default')
    $label = if ($hasDefault) { "$Prompt [$Default]" } else { $Prompt }
    while ($true) {
        $v = (Read-Host $label).Trim()
        if (-not $v -and $hasDefault) { return $Default }
        if ($v -as [int]) { return [int]$v }
        Write-Warn '  Enter a whole number.'
    }
}

function Read-DateValue {
    param([string]$Prompt)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v -as [datetime]) { return [datetime]$v }
        Write-Warn '  Enter a valid date (e.g. 2025-09-01).'
    }
}

function Read-NonEmpty {
    param([string]$Prompt)
    while ($true) {
        $v = (Read-Host $Prompt).Trim()
        if ($v) { return $v }
        Write-Warn '  A value is required.'
    }
}

function Confirm-Action {
    param([string]$Prompt)
    $v = (Read-Host "$Prompt (y/N)").Trim().ToUpper()
    return $v -eq 'Y'
}

#endregion

#region Environment helpers

function Test-Elevation {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsLocal {
    param([string]$ComputerName)
    return [string]::IsNullOrWhiteSpace($ComputerName) -or
           $ComputerName -in @($env:COMPUTERNAME, 'localhost', '.', '127.0.0.1', '::1')
}

function Test-DomainJoined {
    try { return [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain }
    catch { return $false }
}

function Get-TargetComputer {
    param([string]$Prompt = 'Target host (blank = this machine)')
    $name = (Read-Host "  $Prompt").Trim()
    if (Test-IsLocal $name) { return $env:COMPUTERNAME }
    if (Test-Connection -ComputerName $name -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $name }
    Write-Warn "  $name did not answer ICMP; continuing (firewall may block ping)."
    return $name
}

function Import-RequiredModule {
    param([Parameter(Mandatory)][string]$Name, [string]$InstallHint)
    if (Get-Module -Name $Name) { return $true }
    if (Get-Module -ListAvailable -Name $Name) {
        try { Import-Module $Name -ErrorAction Stop; return $true } catch {}
    }
    Write-Bad "  Module '$Name' is not available on this host."
    if ($InstallHint) { Write-Info "  $InstallHint" }
    return $false
}

function Get-Cim {
    param(
        [string]$ComputerName,
        [Parameter(Mandatory)][string]$Class,
        [string]$Filter
    )
    $p = @{ ClassName = $Class; ErrorAction = 'Stop' }
    if ($Filter) { $p.Filter = $Filter }
    if (-not (Test-IsLocal $ComputerName)) { $p.ComputerName = $ComputerName }
    try {
        Get-CimInstance @p
    } catch {
        $where = if (Test-IsLocal $ComputerName) { 'this machine' } else { $ComputerName }
        throw "Could not query $Class on ${where}: $($_.Exception.Message)"
    }
}

#endregion

#region Results and export

function Show-Result {
    param($Data)
    $rows = @($Data)
    if ($rows.Count -eq 0) { Write-Warn '  No matching results.'; return }
    $rows | Format-Table -AutoSize | Out-Host
}

function Export-Result {
    param(
        [Parameter(Mandatory)]$Data,
        [Parameter(Mandatory)][string]$Name,
        [string]$Category = 'General',
        [string]$Note
    )
    $rows = @($Data | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { Write-Warn "  Nothing to export for '$Name'."; return }

    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $csv  = Join-Path $script:Session.OutDir "$safe.csv"
    $json = Join-Path $script:Session.OutDir "$safe.json"
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
    $rows | ConvertTo-Json -Depth 6 | Out-File -FilePath $json -Encoding UTF8

    $capped = if ($rows.Count -gt 500) { $rows | Select-Object -First 500 } else { $rows }
    $script:Session.Sections.Add([pscustomobject]@{
        Title     = $Name
        Category  = $Category
        Time      = Get-Date
        Count     = $rows.Count
        Note      = $Note
        Rows      = $capped
        Truncated = ($rows.Count -gt 500)
        Csv       = $csv
    })
    Write-Good ("  Saved {0} row(s) -> {1}" -f $rows.Count, $csv)
}

function Save-Text {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Content)
    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $path = Join-Path $script:Session.OutDir "$safe.txt"
    $Content | Out-File -FilePath $path -Encoding UTF8
    Write-Good "  Saved -> $path"
    return $path
}

#endregion

#region Menu engine

function Invoke-Menu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [ConsoleColor]$Color = 'White',
        [Parameter(Mandatory)][object[]]$Items,
        [string]$BackLabel = 'Back'
    )
    while ($true) {
        Show-Banner -Subtitle $Title -Color $Color
        foreach ($it in $Items) {
            Write-Host '   [' -ForegroundColor DarkGray -NoNewline
            Write-Host $it.Key -ForegroundColor $Color -NoNewline
            Write-Host ']  ' -ForegroundColor DarkGray -NoNewline
            Write-Host $it.Label -ForegroundColor White
        }
        Write-Host ("   [B]  {0}" -f $BackLabel) -ForegroundColor DarkGray
        Write-Host ''
        $choice = (Read-Host '  Select').Trim().ToUpper()
        if ($choice -in @('B', 'Q', '')) { return }
        $item = $Items | Where-Object { $_.Key -eq $choice } | Select-Object -First 1
        if (-not $item) { continue }
        Write-Host ''
        try { & $item.Action }
        catch { Write-Bad ("  Error: {0}" -f $_.Exception.Message) }
        Wait-Key
    }
}

function New-MenuItem {
    param([string]$Key, [string]$Label, [scriptblock]$Action)
    [pscustomobject]@{ Key = $Key.ToUpper(); Label = $Label; Action = $Action }
}

#endregion

#region Active Directory

$script:RsatHint = 'Install RSAT AD tools: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'

function Assert-ADReady {
    if (-not (Import-RequiredModule ActiveDirectory $script:RsatHint)) { return $false }
    try {
        $null = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        if (-not (Test-DomainJoined)) {
            Write-Bad '  This machine is not joined to a domain, so Active Directory queries cannot run.'
        } else {
            Write-Bad "  Could not reach a domain controller: $($_.Exception.Message)"
        }
        return $false
    }
}

function Get-ADInactiveUser {
    if (-not (Assert-ADReady)) { return }
    $since = Read-DateValue '  Cutoff date (flag enabled users with no logon since)'
    $users = Get-ADUser -Filter { Enabled -eq $true } -Properties LastLogonDate, whenCreated, Department, Title |
        Select-Object SamAccountName, Name, Enabled, whenCreated, LastLogonDate, Department, Title |
        Where-Object { -not $_.LastLogonDate -or $_.LastLogonDate -lt $since } |
        Sort-Object LastLogonDate
    Show-Result $users
    Export-Result -Data $users -Category 'Active Directory' `
        -Name "AD_InactiveUsers_since_$($since.ToString('yyyyMMdd'))" `
        -Note "Enabled users with no logon since $($since.ToString('yyyy-MM-dd')). LastLogonDate comes from the replicated lastLogonTimestamp, so it can lag real activity by up to ~14 days."
}

function Get-ADPasswordAge {
    if (-not (Assert-ADReady)) { return }
    $days = Read-Int '  Password older than N days' -Default 365
    $cut  = (Get-Date).AddDays(-$days)
    $users = Get-ADUser -Filter { Enabled -eq $true } -Properties pwdLastSet, PasswordNeverExpires |
        Select-Object SamAccountName, Name, PasswordNeverExpires,
            @{ n = 'PwdLastSet'; e = { if ($_.pwdLastSet) { [DateTime]::FromFileTime([int64]$_.pwdLastSet) } } },
            @{ n = 'DaysSince';  e = { if ($_.pwdLastSet) { (New-TimeSpan -Start ([DateTime]::FromFileTime([int64]$_.pwdLastSet)) -End (Get-Date)).Days } } } |
        Where-Object { -not $_.PwdLastSet -or $_.PwdLastSet -lt $cut } |
        Sort-Object DaysSince -Descending
    Show-Result $users
    Export-Result -Data $users -Category 'Active Directory' -Name "AD_PasswordAge_over_${days}d" `
        -Note "Enabled users whose password is older than $days days. PasswordNeverExpires accounts are included so you can see them explicitly."
}

function Get-ADLockedOut {
    if (-not (Assert-ADReady)) { return }
    $users = Search-ADAccount -LockedOut -UsersOnly |
        Get-ADUser -Properties LockoutTime, LastBadPasswordAttempt, Enabled |
        Select-Object SamAccountName, Name, Enabled,
            @{ n = 'LockoutTime'; e = { if ($_.LockoutTime) { [DateTime]::FromFileTime($_.LockoutTime) } } },
            LastBadPasswordAttempt |
        Sort-Object LockoutTime -Descending
    Show-Result $users
    Export-Result -Data $users -Category 'Active Directory' -Name 'AD_LockedOutUsers' `
        -Note 'Currently locked accounts. Use Investigation > Lockout source to trace where the bad passwords come from.'
}

function Get-ADPrivilegedMember {
    if (-not (Assert-ADReady)) { return }
    $groups = 'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
              'Account Operators', 'Backup Operators', 'Server Operators', 'Group Policy Creator Owners'
    $rows = foreach ($g in $groups) {
        try {
            Get-ADGroupMember -Identity $g -Recursive -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Group          = $g
                    Member         = $_.Name
                    SamAccountName = $_.SamAccountName
                    Class          = $_.ObjectClass
                }
            }
        } catch {}
    }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Active Directory' -Name 'AD_PrivilegedGroupMembers' `
        -Note 'Recursive membership of the built-in privileged groups. Review anything unexpected here first.'
}

function Get-ADStaleComputer {
    if (-not (Assert-ADReady)) { return }
    $days = Read-Int '  Computer inactive more than N days' -Default 90
    $rows = Search-ADAccount -ComputersOnly -AccountInactive -TimeSpan ([timespan]::FromDays($days)) |
        Get-ADComputer -Properties OperatingSystem, LastLogonDate, whenCreated, Enabled |
        Select-Object Name, Enabled, OperatingSystem, LastLogonDate, whenCreated |
        Sort-Object LastLogonDate
    Show-Result $rows
    Export-Result -Data $rows -Category 'Active Directory' -Name "AD_StaleComputers_over_${days}d" `
        -Note "Computer objects with no logon in $days+ days. Candidates for cleanup."
}

function Get-ADGroupMembership {
    if (-not (Assert-ADReady)) { return }
    $group = Read-NonEmpty '  AD group (name, SAM, or DN)'
    $rows = Get-ADGroupMember -Identity $group -Recursive -ErrorAction Stop | ForEach-Object {
        if ($_.ObjectClass -eq 'user') {
            Get-ADUser $_ -Properties mail, Department, Title, Enabled |
                Select-Object SamAccountName, Name, Enabled, mail, Department, Title
        } else {
            [pscustomobject]@{ SamAccountName = $_.SamAccountName; Name = $_.Name; Enabled = $null; mail = $null; Department = $null; Title = "($($_.ObjectClass))" }
        }
    } | Sort-Object Name
    Show-Result $rows
    Export-Result -Data $rows -Category 'Active Directory' -Name "AD_GroupMembership_$group" `
        -Note "Recursive membership of '$group'."
}

function Get-ADRecentAccount {
    if (-not (Assert-ADReady)) { return }
    $days = Read-Int '  Accounts created within N days' -Default 30
    $cut  = (Get-Date).AddDays(-$days)
    $rows = Get-ADUser -Filter { whenCreated -ge $cut } -Properties whenCreated, Enabled, Description, Department |
        Select-Object SamAccountName, Name, Enabled, whenCreated, Department, Description |
        Sort-Object whenCreated -Descending
    Show-Result $rows
    Export-Result -Data $rows -Category 'Active Directory' -Name "AD_RecentAccounts_${days}d" `
        -Note "User accounts created in the last $days days."
}

function Invoke-ADMenu {
    Invoke-Menu -Title 'Active Directory' -Color Green -Items @(
        New-MenuItem 1 'Inactive users since a date'          { Get-ADInactiveUser }
        New-MenuItem 2 'Users with password older than N days' { Get-ADPasswordAge }
        New-MenuItem 3 'Locked-out accounts'                   { Get-ADLockedOut }
        New-MenuItem 4 'Privileged group audit'                { Get-ADPrivilegedMember }
        New-MenuItem 5 'Stale computer accounts'               { Get-ADStaleComputer }
        New-MenuItem 6 'Group membership report'               { Get-ADGroupMembership }
        New-MenuItem 7 'Recently created accounts'             { Get-ADRecentAccount }
    )
}

#endregion

#region Investigation

$script:LogonTypeMap = @{
    2 = 'Interactive'; 3 = 'Network'; 4 = 'Batch'; 5 = 'Service'; 7 = 'Unlock'
    8 = 'NetworkCleartext'; 9 = 'NewCredentials'; 10 = 'RemoteInteractive'; 11 = 'CachedInteractive'
}

$script:LogonFailMap = @{
    '0xC0000064' = 'User does not exist'
    '0xC000006A' = 'Bad password'
    '0xC0000234' = 'Account locked out'
    '0xC0000072' = 'Account disabled'
    '0xC0000070' = 'Workstation restriction'
    '0xC0000193' = 'Account expired'
    '0xC0000071' = 'Password expired'
    '0xC0000133' = 'Clock skew between hosts'
    '0xC0000224' = 'Password must change'
    '0xC000015B' = 'Logon type not granted'
}

function ConvertFrom-WinEventXml {
    param($Event)
    $data = @{}
    try {
        $x = [xml]$Event.ToXml()
        foreach ($d in $x.Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    } catch {}
    return $data
}

function Get-EventsSince {
    param([Parameter(Mandatory)][string]$LogName, [int[]]$Id, [Parameter(Mandatory)][datetime]$Start, [string]$ComputerName)
    $filter = @{ LogName = $LogName; StartTime = $Start }
    if ($Id) { $filter.Id = $Id }
    $p = @{ FilterHashtable = $filter; ErrorAction = 'Stop' }
    if (-not (Test-IsLocal $ComputerName)) { $p.ComputerName = $ComputerName }
    try {
        Get-WinEvent @p
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'No events were found') { return @() }
        $where = if (Test-IsLocal $ComputerName) { 'this machine' } else { $ComputerName }
        if ($_.Exception -is [System.UnauthorizedAccessException] -or $msg -match 'access is denied|unauthorized') {
            throw "Access denied reading '$LogName' on ${where}. Run MSAT as Administrator."
        }
        if ($msg -match 'no such|could not be found|specified channel') {
            throw "Log '$LogName' is not available on ${where}."
        }
        throw
    }
}

function Get-LogonActivity {
    $host_ = Get-TargetComputer
    $hours = Read-Int '  Hours back' -Default 24
    $start = (Get-Date).AddHours(-$hours)
    $events = Get-EventsSince -LogName Security -Id 4624, 4625 -Start $start -ComputerName $host_
    $rows = foreach ($e in $events) {
        $d = ConvertFrom-WinEventXml $e
        $lt = $d['LogonType']
        [pscustomobject]@{
            Time      = $e.TimeCreated
            Result    = if ($e.Id -eq 4624) { 'Success' } else { 'Failed' }
            Account   = $d['TargetUserName']
            Domain    = $d['TargetDomainName']
            LogonType = if ($lt -and $script:LogonTypeMap.ContainsKey([int]$lt)) { $script:LogonTypeMap[[int]$lt] } else { $lt }
            Source    = if ($d['IpAddress'] -and $d['IpAddress'] -ne '-') { $d['IpAddress'] } else { $d['WorkstationName'] }
        }
    }
    $rows = @($rows | Sort-Object Time -Descending)
    $summary = $rows | Group-Object Account, Result | ForEach-Object {
        [pscustomobject]@{ Account = ($_.Group[0].Account); Result = ($_.Group[0].Result); Count = $_.Count }
    } | Sort-Object Count -Descending
    Write-Head '  Sign-in summary (account / result):'
    Show-Result ($summary | Select-Object -First 25)
    Export-Result -Data $rows -Category 'Investigation' -Name "IR_Logons_${host_}_${hours}h" `
        -Note "Security 4624/4625 on $host_ over the last $hours hours."
}

function Get-FailedLogonAnalysis {
    $host_ = Get-TargetComputer
    $hours = Read-Int '  Hours back' -Default 24
    $start = (Get-Date).AddHours(-$hours)
    $events = Get-EventsSince -LogName Security -Id 4625 -Start $start -ComputerName $host_
    $rows = foreach ($e in $events) {
        $d = ConvertFrom-WinEventXml $e
        $sub = $d['SubStatus']
        [pscustomobject]@{
            Time      = $e.TimeCreated
            Account   = $d['TargetUserName']
            Reason    = if ($sub -and $script:LogonFailMap.ContainsKey($sub)) { $script:LogonFailMap[$sub] } else { $sub }
            LogonType = $d['LogonType']
            SourceIP  = $d['IpAddress']
            Source    = $d['WorkstationName']
            Process   = $d['ProcessName']
        }
    }
    $rows = @($rows | Sort-Object Time -Descending)
    if ($rows.Count -eq 0) { Write-Warn '  No failed logons in the window.'; return }
    Write-Head '  Top accounts by failed logons:'
    Show-Result ($rows | Group-Object Account | Sort-Object Count -Descending |
        Select-Object -First 15 Name, Count)
    Write-Head '  Top source IPs:'
    Show-Result ($rows | Where-Object { $_.SourceIP -and $_.SourceIP -ne '-' } |
        Group-Object SourceIP | Sort-Object Count -Descending | Select-Object -First 15 Name, Count)
    Export-Result -Data $rows -Category 'Investigation' -Name "IR_FailedLogons_${host_}_${hours}h" `
        -Note "Failed logon (4625) detail on $host_ with decoded failure reasons."
}

function Get-LockoutSource {
    $host_ = Get-TargetComputer '  Domain controller to query (blank = this machine)'
    $hours = Read-Int '  Hours back' -Default 48
    $start = (Get-Date).AddHours(-$hours)
    $events = Get-EventsSince -LogName Security -Id 4740 -Start $start -ComputerName $host_
    $rows = foreach ($e in $events) {
        $d = ConvertFrom-WinEventXml $e
        [pscustomobject]@{
            Time        = $e.TimeCreated
            LockedUser  = $d['TargetUserName']
            SourceHost  = $d['TargetDomainName']
            LockedOnDC  = $d['SubjectUserName']
        }
    }
    $rows = @($rows | Sort-Object Time -Descending)
    if ($rows.Count -eq 0) {
        Write-Warn '  No 4740 lockout events found. Note: these are logged on the DC that holds the PDC emulator role.'
    }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Investigation' -Name "IR_LockoutSource_${hours}h" `
        -Note '4740 lockout events. SourceHost is the machine that submitted the bad credentials.'
}

function Get-AccountChangeEvent {
    $host_ = Get-TargetComputer
    $hours = Read-Int '  Hours back' -Default 72
    $start = (Get-Date).AddHours(-$hours)
    $ids = 4720, 4722, 4725, 4726, 4738, 4724, 4728, 4732, 4756, 4767
    $map = @{
        4720 = 'User created'; 4722 = 'User enabled'; 4725 = 'User disabled'; 4726 = 'User deleted'
        4738 = 'User changed'; 4724 = 'Password reset'; 4728 = 'Added to global group'
        4732 = 'Added to local group'; 4756 = 'Added to universal group'; 4767 = 'Account unlocked'
    }
    $events = Get-EventsSince -LogName Security -Id $ids -Start $start -ComputerName $host_
    $rows = foreach ($e in $events) {
        $d = ConvertFrom-WinEventXml $e
        [pscustomobject]@{
            Time    = $e.TimeCreated
            Action  = if ($map.ContainsKey([int]$e.Id)) { $map[[int]$e.Id] } else { $e.Id }
            Target  = $d['TargetUserName']
            Group   = $d['MemberName']
            By      = $d['SubjectUserName']
        }
    }
    $rows = @($rows | Sort-Object Time -Descending)
    Show-Result $rows
    Export-Result -Data $rows -Category 'Investigation' -Name "IR_AccountChanges_${host_}_${hours}h" `
        -Note 'User and group-membership changes from the Security log.'
}

function Get-PersistenceSnapshot {
    $rows = New-Object System.Collections.Generic.List[object]
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($k in $runKeys) {
        if (Test-Path $k) {
            $props = Get-ItemProperty $k
            foreach ($p in $props.PSObject.Properties) {
                if ($p.Name -notlike 'PS*') {
                    $rows.Add([pscustomobject]@{ Type = 'RunKey'; Location = $k; Name = $p.Name; Value = $p.Value })
                }
            }
        }
    }
    Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | ForEach-Object {
        $rows.Add([pscustomobject]@{ Type = 'StartupCmd'; Location = $_.Location; Name = $_.Name; Value = $_.Command })
    }
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -and $_.PathName -notmatch '(?i)\\Windows\\' } | ForEach-Object {
            $rows.Add([pscustomobject]@{ Type = 'Service'; Location = $_.StartMode; Name = $_.Name; Value = $_.PathName })
        }
    Show-Result ($rows | Sort-Object Type)
    Export-Result -Data $rows -Category 'Investigation' -Name 'IR_Persistence' `
        -Note 'Run keys, startup commands, and services running from non-Windows paths. Review the Value column for anything unusual.'
}

function Get-SysmonSummary {
    $host_ = Get-TargetComputer
    $hours = Read-Int '  Hours back' -Default 24
    $start = (Get-Date).AddHours(-$hours)
    try {
        $events = Get-EventsSince -LogName 'Microsoft-Windows-Sysmon/Operational' -Start $start -ComputerName $host_
    } catch {
        Write-Warn '  Sysmon channel not found on this host.'; return
    }
    $top = $events | Group-Object Id | Sort-Object Count -Descending |
        Select-Object @{ n = 'EventId'; e = { $_.Name } }, Count
    Show-Result $top
    $detail = $events | Select-Object TimeCreated, Id, Message
    Export-Result -Data $detail -Category 'Investigation' -Name "IR_Sysmon_${host_}_${hours}h" `
        -Note 'Sysmon operational events. Top event-ID counts shown above.'
}

function Get-PowerShellLogEvent {
    $host_ = Get-TargetComputer
    $hours = Read-Int '  Hours back' -Default 24
    $start = (Get-Date).AddHours(-$hours)
    try {
        $events = Get-EventsSince -LogName 'Microsoft-Windows-PowerShell/Operational' -Id 4104 -Start $start -ComputerName $host_
    } catch {
        Write-Warn '  No PowerShell script-block logging events (4104) available.'; return
    }
    $rows = $events | ForEach-Object {
        $d = ConvertFrom-WinEventXml $_
        [pscustomobject]@{ Time = $_.TimeCreated; Level = $_.LevelDisplayName; Script = $d['ScriptBlockText'] }
    } | Sort-Object Time -Descending
    Show-Result ($rows | Select-Object Time, Level, @{ n = 'Script'; e = { ($_.Script -replace '\s+', ' ') } } | Select-Object -First 20)
    Export-Result -Data $rows -Category 'Investigation' -Name "IR_PowerShellLog_${host_}_${hours}h" `
        -Note 'Script-block logging (4104). Full script text is in the CSV/JSON.'
}

function Invoke-TriageBundle {
    Write-Info '  Collecting local triage bundle...'
    Export-Result -Category 'Triage' -Name 'Triage_Processes' -Note 'Running processes with image paths.' `
        -Data (Get-Process | Select-Object Name, Id, CPU,
            @{ n = 'WS_MB'; e = { [math]::Round($_.WS / 1MB, 1) } }, Path)
    Export-Result -Category 'Triage' -Name 'Triage_Services' -Note 'Service configuration.' `
        -Data (Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName)
    Export-Result -Category 'Triage' -Name 'Triage_Listeners' -Note 'Listening TCP sockets mapped to processes.' `
        -Data (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
            $procName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            [pscustomobject]@{ LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; Process = $procName; PID = $_.OwningProcess }
        })
    Export-Result -Category 'Triage' -Name 'Triage_ScheduledTasks' -Note 'Enabled scheduled tasks.' `
        -Data (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object State -ne 'Disabled' |
            Select-Object TaskPath, TaskName, State,
                @{ n = 'Action'; e = { ($_.Actions.Execute -join '; ') } })
    Get-LocalAdminReport -Silent
    Write-Good "  Triage bundle written to $($script:Session.OutDir)"
}

function Invoke-InvestigationMenu {
    Invoke-Menu -Title 'Investigation' -Color Yellow -Items @(
        New-MenuItem 1 'Logon activity summary (4624/4625)' { Get-LogonActivity }
        New-MenuItem 2 'Failed logon analysis (4625)'        { Get-FailedLogonAnalysis }
        New-MenuItem 3 'Account lockout source (4740)'       { Get-LockoutSource }
        New-MenuItem 4 'Account / group change events'       { Get-AccountChangeEvent }
        New-MenuItem 5 'Persistence & autoruns snapshot'     { Get-PersistenceSnapshot }
        New-MenuItem 6 'Sysmon event summary'                { Get-SysmonSummary }
        New-MenuItem 7 'PowerShell script-block logging'     { Get-PowerShellLogEvent }
        New-MenuItem 8 'Full local triage bundle'            { Invoke-TriageBundle }
    )
}

#endregion

#region Endpoint / health

function Get-HealthSnapshot {
    $host_ = Get-TargetComputer
    $os  = Get-Cim -ComputerName $host_ -Class Win32_OperatingSystem
    $cs  = Get-Cim -ComputerName $host_ -Class Win32_ComputerSystem
    $cpu = Get-Cim -ComputerName $host_ -Class Win32_Processor
    $disks = Get-Cim -ComputerName $host_ -Class Win32_LogicalDisk -Filter 'DriveType=3' |
        ForEach-Object { "{0} {1}GB free / {2}GB" -f $_.DeviceID, [math]::Round($_.FreeSpace / 1GB, 1), [math]::Round($_.Size / 1GB, 1) }
    $obj = [pscustomobject]@{
        Computer     = $host_
        OS           = $os.Caption
        Version      = $os.Version
        LastBoot     = $os.LastBootUpTime
        UptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
        CpuLoadPct   = ($cpu | Measure-Object -Property LoadPercentage -Average).Average
        RamTotalGB   = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        RamFreeGB    = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        Disks        = ($disks -join '  |  ')
        Model        = "$($cs.Manufacturer) $($cs.Model)"
    }
    $obj | Format-List | Out-Host
    Export-Result -Data $obj -Category 'Endpoint' -Name "Health_$host_" -Note "Point-in-time health snapshot for $host_."
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons.Add('Component Based Servicing') }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons.Add('Windows Update') }
    $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($pfr) { $reasons.Add('Pending file rename') }
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $pending -and $active -ne $pending) { $reasons.Add('Pending computer rename') }

    if ($reasons.Count -eq 0) { Write-Good "  No pending reboot on $env:COMPUTERNAME." }
    else { Write-Warn ("  Reboot pending: {0}" -f ($reasons -join ', ')) }
    $obj = [pscustomobject]@{ Computer = $env:COMPUTERNAME; RebootPending = ($reasons.Count -gt 0); Reasons = ($reasons -join ', ') }
    Export-Result -Data $obj -Category 'Endpoint' -Name 'Endpoint_PendingReboot' -Note 'Local pending-reboot flags from the registry.'
}

function Get-WindowsUpdateStatus {
    $host_ = Get-TargetComputer
    $hotfix = Get-HotFix -ComputerName $host_ -ErrorAction SilentlyContinue |
        Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn
    Write-Head '  Last 10 installed updates:'
    Show-Result $hotfix
    Export-Result -Data $hotfix -Category 'Endpoint' -Name "Endpoint_Hotfixes_$host_" -Note "Most recent hotfixes on $host_."

    if (Test-IsLocal $host_) {
        try {
            Write-Info '  Querying pending updates (local)...'
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $pending = $searcher.Search("IsInstalled=0 and Type='Software'").Updates
            $rows = foreach ($u in $pending) {
                [pscustomobject]@{ Title = $u.Title; Severity = $u.MsrcSeverity; RebootRequired = $u.InstallationBehavior.RebootBehavior }
            }
            if ($rows) {
                Write-Warn ("  {0} update(s) pending." -f @($rows).Count)
                Export-Result -Data $rows -Category 'Endpoint' -Name 'Endpoint_PendingUpdates' -Note 'Software updates not yet installed (Microsoft.Update COM API).'
            } else { Write-Good '  No pending software updates.' }
        } catch { Write-Warn "  Could not query pending updates: $($_.Exception.Message)" }
    }
}

function Get-DiskHealthReport {
    $host_ = Get-TargetComputer
    $drives = Get-Cim -ComputerName $host_ -Class Win32_DiskDrive |
        Select-Object Model, SerialNumber, InterfaceType,
            @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }, Status
    Show-Result $drives
    if (Test-IsLocal $host_) {
        $phys = Get-PhysicalDisk -ErrorAction SilentlyContinue |
            Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus,
                @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }
        if ($phys) { Write-Head '  Physical disk health:'; Show-Result $phys }
    }
    Export-Result -Data $drives -Category 'Endpoint' -Name "Endpoint_Disks_$host_" -Note "Disk models and reported status for $host_."
}

function Get-BitLockerReport {
    try { Import-Module BitLocker -ErrorAction Stop } catch { Write-Warn '  BitLocker module unavailable.'; return }
    $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint, VolumeType,
        ProtectionStatus, EncryptionMethod,
        @{ n = 'CapacityGB'; e = { [math]::Round($_.CapacityGB, 1) } },
        @{ n = 'EncryptionPct'; e = { $_.EncryptionPercentage } }
    if (-not $vols) { Write-Warn '  No BitLocker volumes reported.'; return }
    Show-Result $vols
    Export-Result -Data $vols -Category 'Endpoint' -Name 'Endpoint_BitLocker' -Note 'BitLocker protection status per volume.'
}

function Get-CertificateExpiry {
    $days = Read-Int '  Warn on certs expiring within N days' -Default 60
    $cut  = (Get-Date).AddDays($days)
    $rows = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.NotAfter -lt $cut } |
        Select-Object Subject, Issuer, NotAfter,
            @{ n = 'DaysLeft'; e = { (New-TimeSpan -Start (Get-Date) -End $_.NotAfter).Days } }, Thumbprint |
        Sort-Object NotAfter
    if (-not $rows) { Write-Good "  No LocalMachine\My certs expiring within $days days."; return }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Endpoint' -Name "Endpoint_CertExpiry_${days}d" -Note "Machine certificates expiring within $days days."
}

function Get-BackupStatus {
    $agents = 'VeeamBackupSvc', 'VeeamEndpointBackupSvc', 'CBVSCService', 'BackupExecAgentAccelerator',
              'AcronisAgent', 'StorageCraftImageManager', 'BackupExecRPCService', 'AdvancedMonitoringAgent',
              'Macrium Service', 'ShadowProtectSvc'
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -in $agents -or $_.DisplayName -match '(?i)backup|veeam|acronis|datto|cove|macrium|shadowprotect' } |
        Select-Object Name, DisplayName, Status, StartType
    if ($svc) { Write-Head '  Backup-related services:'; Show-Result $svc }
    else { Write-Warn '  No known backup agent services detected.' }

    $wb = $null
    try { $wb = Get-WBSummary -ErrorAction Stop } catch {}
    if ($wb) {
        $obj = [pscustomobject]@{
            LastBackup       = $wb.LastSuccessfulBackupTime
            LastResult       = $wb.LastBackupResultHR
            NextBackup       = $wb.NextBackupTime
            NumberOfVersions = $wb.NumberOfVersions
        }
        Write-Head '  Windows Server Backup:'
        $obj | Format-List | Out-Host
        Export-Result -Data $obj -Category 'Endpoint' -Name 'Endpoint_WSB' -Note 'Windows Server Backup summary.'
    }
    if ($svc) { Export-Result -Data $svc -Category 'Endpoint' -Name 'Endpoint_BackupServices' -Note 'Detected backup agent services and their run state.' }
}

function Get-LocalAdminReport {
    param([switch]$Silent)
    try {
        $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
            Select-Object Name, ObjectClass, PrincipalSource
    } catch {
        $admins = (net localgroup administrators) | Where-Object { $_ -and $_ -notmatch '^(Alias|Comment|Members|-----|The command)' } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Trim(); ObjectClass = 'Unknown'; PrincipalSource = 'net.exe' } }
    }
    if (-not $Silent) { Show-Result $admins }
    Export-Result -Data $admins -Category 'Endpoint' -Name "Endpoint_LocalAdmins_$env:COMPUTERNAME" -Note 'Members of the local Administrators group.'
}

function Get-WingetUpgradable {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warn '  winget is not available on this host.'; return }
    Write-Info '  Running winget upgrade...'
    $out = winget upgrade --include-unknown 2>&1 | Out-String
    Write-Info $out
    Save-Text -Name "Endpoint_WingetUpgrade_$env:COMPUTERNAME" -Content $out | Out-Null
}

function Invoke-EndpointMenu {
    Invoke-Menu -Title 'Endpoint / Health' -Color White -Items @(
        New-MenuItem 1 'Host health snapshot'          { Get-HealthSnapshot }
        New-MenuItem 2 'Pending reboot check (local)'   { Test-PendingReboot }
        New-MenuItem 3 'Windows Update status'          { Get-WindowsUpdateStatus }
        New-MenuItem 4 'Disk & SMART health'            { Get-DiskHealthReport }
        New-MenuItem 5 'BitLocker status'               { Get-BitLockerReport }
        New-MenuItem 6 'Certificate expiry (local)'     { Get-CertificateExpiry }
        New-MenuItem 7 'Backup agent & job status'      { Get-BackupStatus }
        New-MenuItem 8 'Local administrators audit'     { Get-LocalAdminReport }
        New-MenuItem 9 'Winget upgradable packages'     { Get-WingetUpgradable }
    )
}

#endregion

#region Network & inventory

function Invoke-PingSweep {
    $base = Read-NonEmpty '  Base /24 (e.g. 192.168.1)'
    $base = $base.TrimEnd('.')
    Write-Info '  Sweeping 1-254 ...'
    $pings = 1..254 | ForEach-Object {
        $p = New-Object System.Net.NetworkInformation.Ping
        [pscustomobject]@{ IP = "$base.$_"; Task = $p.SendPingAsync("$base.$_", 500) }
    }
    [System.Threading.Tasks.Task]::WaitAll($pings.Task)
    $live = foreach ($p in $pings) {
        if ($p.Task.Result.Status -eq 'Success') {
            $name = try { [System.Net.Dns]::GetHostEntry($p.IP).HostName } catch { '' }
            [pscustomobject]@{ IP = $p.IP; RTTms = $p.Task.Result.RoundtripTime; Hostname = $name }
        }
    }
    $live = @($live | Sort-Object { [version]($_.IP) })
    Show-Result $live
    Export-Result -Data $live -Category 'Network' -Name "Net_PingSweep_${base}_0" -Note "Live hosts on $base.0/24."
}

function Get-HostInventory {
    $host_ = Get-TargetComputer '  Host to inventory'
    $os   = Get-Cim -ComputerName $host_ -Class Win32_OperatingSystem
    $cpu  = Get-Cim -ComputerName $host_ -Class Win32_Processor
    $cs   = Get-Cim -ComputerName $host_ -Class Win32_ComputerSystem
    $bios = Get-Cim -ComputerName $host_ -Class Win32_BIOS
    $obj = [pscustomobject]@{
        Computer   = $host_
        OS         = $os.Caption
        OSVersion  = $os.Version
        LastBoot   = $os.LastBootUpTime
        CPU        = ($cpu.Name | Select-Object -First 1)
        Cores      = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
        RamGB      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        Manufacturer = $cs.Manufacturer
        Model      = $cs.Model
        BIOS       = $bios.SMBIOSBIOSVersion
        Serial     = $bios.SerialNumber
    }
    $obj | Format-List | Out-Host
    Export-Result -Data $obj -Category 'Network' -Name "Net_Inventory_$host_" -Note "Hardware/OS inventory for $host_."
}

function Get-NetworkSnapshot {
    Write-Info '  Gathering local network snapshot...'
    Save-Text -Name 'Net_ipconfig'  -Content (ipconfig /all | Out-String) | Out-Null
    Save-Text -Name 'Net_routes'     -Content (route print | Out-String) | Out-Null
    Save-Text -Name 'Net_arp'        -Content (arp -a | Out-String) | Out-Null
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $procName = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        [pscustomobject]@{ LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; Process = $procName; PID = $_.OwningProcess }
    } | Sort-Object LocalPort
    Show-Result $listeners
    Export-Result -Data $listeners -Category 'Network' -Name 'Net_Listeners' -Note 'Listening TCP sockets mapped to owning processes.'
}

function Test-PortSet {
    $target = Read-NonEmpty '  Target host or IP'
    $portsRaw = Read-NonEmpty '  Ports (comma-separated, e.g. 80,443,3389)'
    $ports = $portsRaw -split '[,\s]+' | Where-Object { $_ -as [int] } | ForEach-Object { [int]$_ }
    $rows = foreach ($port in $ports) {
        $client = New-Object System.Net.Sockets.TcpClient
        $ok = $false
        try {
            $iar = $client.BeginConnect($target, $port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(1000) -and $client.Connected
        } catch {} finally { $client.Close() }
        [pscustomobject]@{ Host = $target; Port = $port; Open = $ok }
    }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Network' -Name "Net_PortCheck_$target" -Note "TCP connect test to $target."
}

function Get-DomainHealth {
    $cs = Get-CimInstance Win32_ComputerSystem
    if (-not $cs.PartOfDomain) {
        Write-Warn "  This machine is not domain-joined (workgroup: $($cs.Workgroup)). Domain checks skipped."
        return
    }
    $domain = $cs.Domain
    $rows = New-Object System.Collections.Generic.List[object]
    $rows.Add([pscustomobject]@{ Check = 'Machine domain'; Result = $domain })
    try {
        $dc = nltest /dsgetdc:$domain 2>&1 | Out-String
        Save-Text -Name 'Net_DsGetDc' -Content $dc | Out-Null
        $dcName = ($dc -split "`n" | Where-Object { $_ -match 'DC:' } | Select-Object -First 1)
        $rows.Add([pscustomobject]@{ Check = 'Located DC'; Result = ($dcName -replace '\s+', ' ').Trim() })
    } catch { $rows.Add([pscustomobject]@{ Check = 'Located DC'; Result = "error: $($_.Exception.Message)" }) }
    try {
        $srv = Resolve-DnsName -Type SRV "_ldap._tcp.dc._msdcs.$domain" -ErrorAction Stop |
            Where-Object { $_.QueryType -eq 'SRV' } | Select-Object -ExpandProperty NameTarget
        $rows.Add([pscustomobject]@{ Check = 'LDAP SRV records'; Result = (($srv | Sort-Object -Unique) -join ', ') })
    } catch { $rows.Add([pscustomobject]@{ Check = 'LDAP SRV records'; Result = "error: $($_.Exception.Message)" }) }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Network' -Name 'Net_DomainHealth' -Note 'Domain controller discovery and LDAP SRV resolution.'
}

function Invoke-NetworkMenu {
    Invoke-Menu -Title 'Network & Inventory' -Color Cyan -Items @(
        New-MenuItem 1 'Ping sweep a /24'              { Invoke-PingSweep }
        New-MenuItem 2 'Host inventory (CIM)'          { Get-HostInventory }
        New-MenuItem 3 'Local network snapshot'        { Get-NetworkSnapshot }
        New-MenuItem 4 'Port check to a host'          { Test-PortSet }
        New-MenuItem 5 'Domain / DNS health'           { Get-DomainHealth }
    )
}

#endregion

#region Microsoft 365 / Entra

$script:GraphScopes = @(
    'User.Read.All', 'Directory.Read.All', 'AuditLog.Read.All',
    'Reports.Read.All', 'RoleManagement.Read.Directory', 'IdentityRiskyUser.Read.All'
)

function Connect-Msat365 {
    if (-not (Import-RequiredModule Microsoft.Graph.Authentication 'Install-Module Microsoft.Graph -Scope CurrentUser')) { return }
    try {
        Connect-MgGraph -Scopes $script:GraphScopes -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext
        $org = try { (Get-MgOrganization -ErrorAction Stop).DisplayName } catch { '(unknown)' }
        $script:Session.Graph = $true
        Write-Good "  Connected: $org  as  $($ctx.Account)"
    } catch { Write-Bad "  Graph connect failed: $($_.Exception.Message)" }
}

function Assert-Graph {
    if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
        Write-Warn '  Not connected. Use [1] Connect first.'
        return $false
    }
    return $true
}

function Get-365UserReadout {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Users)) { return }
    $upn = Read-NonEmpty '  User principal name (email)'
    $u = Get-MgUser -UserId $upn -Property Id, DisplayName, UserPrincipalName, AccountEnabled, CreatedDateTime, UserType, SignInActivity -ErrorAction Stop
    $lic = (Get-MgUserLicenseDetail -UserId $upn -ErrorAction SilentlyContinue).SkuPartNumber
    $methods = (Get-MgUserAuthenticationMethod -UserId $upn -ErrorAction SilentlyContinue).AdditionalProperties |
        ForEach-Object { ($_['@odata.type'] -replace '#microsoft.graph.', '') }
    $obj = [pscustomobject]@{
        DisplayName   = $u.DisplayName
        UPN           = $u.UserPrincipalName
        Enabled       = $u.AccountEnabled
        Type          = $u.UserType
        Created       = $u.CreatedDateTime
        LastSignIn    = $u.SignInActivity.LastSignInDateTime
        Licenses      = ($lic -join ', ')
        AuthMethods   = (($methods | Sort-Object -Unique) -join ', ')
    }
    $obj | Format-List | Out-Host
    Export-Result -Data $obj -Category 'Microsoft 365' -Name "365_User_$upn" -Note "Account, license, and registered auth methods for $upn."
}

function Get-365MfaRegistration {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Reports)) { return }
    $rows = Get-MgReportAuthenticationMethodUserRegistrationDetail -All -ErrorAction Stop |
        Select-Object UserPrincipalName, IsAdmin, IsMfaRegistered, IsMfaCapable, IsPasswordlessCapable,
            @{ n = 'Methods'; e = { ($_.MethodsRegistered -join ', ') } } |
        Sort-Object IsMfaRegistered, UserPrincipalName
    $noMfa = @($rows | Where-Object { -not $_.IsMfaRegistered })
    Write-Warn ("  {0} of {1} users are NOT MFA-registered." -f $noMfa.Count, @($rows).Count)
    Show-Result ($noMfa | Select-Object -First 25 UserPrincipalName, IsAdmin, Methods)
    Export-Result -Data $rows -Category 'Microsoft 365' -Name '365_MfaRegistration' -Note 'Per-user authentication method registration (Entra reports API).'
}

function Get-365LicenseSummary {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Identity.DirectoryManagement)) { return }
    $rows = Get-MgSubscribedSku -ErrorAction Stop | Select-Object SkuPartNumber,
        @{ n = 'Enabled'; e = { $_.PrepaidUnits.Enabled } },
        @{ n = 'Consumed'; e = { $_.ConsumedUnits } },
        @{ n = 'Available'; e = { $_.PrepaidUnits.Enabled - $_.ConsumedUnits } } |
        Sort-Object SkuPartNumber
    Show-Result $rows
    Export-Result -Data $rows -Category 'Microsoft 365' -Name '365_Licenses' -Note 'Subscribed SKUs with consumed vs. available seats.'
}

function Get-365AdminRole {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Identity.DirectoryManagement)) { return }
    $rows = foreach ($role in Get-MgDirectoryRole -ErrorAction Stop) {
        Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                Role = $role.DisplayName
                Member = $_.AdditionalProperties['displayName']
                UPN = $_.AdditionalProperties['userPrincipalName']
            }
        }
    }
    $rows = @($rows | Sort-Object Role, Member)
    Show-Result $rows
    Export-Result -Data $rows -Category 'Microsoft 365' -Name '365_AdminRoles' -Note 'Members of active Entra directory roles.'
}

function Get-365RiskyUser {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Identity.SignIns)) { return }
    try {
        $rows = Get-MgRiskyUser -All -ErrorAction Stop |
            Where-Object { $_.RiskLevel -ne 'none' } |
            Select-Object UserPrincipalName, RiskLevel, RiskState, RiskLastUpdatedDateTime |
            Sort-Object RiskLevel -Descending
    } catch { Write-Warn "  Risky users need Entra ID P2. ($($_.Exception.Message))"; return }
    if (-not $rows) { Write-Good '  No users currently flagged at risk.'; return }
    Show-Result $rows
    Export-Result -Data $rows -Category 'Microsoft 365' -Name '365_RiskyUsers' -Note 'Users flagged by Entra Identity Protection.'
}

function Get-365SignIn {
    if (-not (Assert-Graph)) { return }
    if (-not (Import-RequiredModule Microsoft.Graph.Reports)) { return }
    $upn = Read-NonEmpty '  User principal name (email)'
    $rows = Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn'" -Top 50 -ErrorAction Stop |
        Select-Object CreatedDateTime, AppDisplayName, IpAddress,
            @{ n = 'City'; e = { $_.Location.City } },
            @{ n = 'Status'; e = { if ($_.Status.ErrorCode -eq 0) { 'Success' } else { "Fail ($($_.Status.ErrorCode))" } } } |
        Sort-Object CreatedDateTime -Descending
    Show-Result $rows
    Export-Result -Data $rows -Category 'Microsoft 365' -Name "365_SignIns_$upn" -Note "Recent interactive sign-ins for $upn (max 50)."
}

function Disconnect-Msat365 {
    try { Disconnect-MgGraph -ErrorAction Stop | Out-Null; Write-Good '  Disconnected from Graph.' }
    catch { Write-Warn '  No active Graph session.' }
    $script:Session.Graph = $false
}

function Invoke-365Menu {
    Invoke-Menu -Title 'Microsoft 365 / Entra' -Color Magenta -Items @(
        New-MenuItem 1 'Connect to tenant'              { Connect-Msat365 }
        New-MenuItem 2 'User quick read-out'            { Get-365UserReadout }
        New-MenuItem 3 'MFA registration report'        { Get-365MfaRegistration }
        New-MenuItem 4 'License usage summary'          { Get-365LicenseSummary }
        New-MenuItem 5 'Admin role members'             { Get-365AdminRole }
        New-MenuItem 6 'Risky users (P2)'               { Get-365RiskyUser }
        New-MenuItem 7 'User sign-in history'           { Get-365SignIn }
        New-MenuItem 8 'Disconnect'                     { Disconnect-Msat365 }
    )
}

#endregion

#region HTML report

$script:ReportCss = @'
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; font-family: "Segoe UI", system-ui, sans-serif; background: #0d1117; color: #c9d1d9; }
header { padding: 24px 28px; border-bottom: 1px solid #21262d; background: #010409; }
header h1 { margin: 0; font-size: 20px; letter-spacing: .5px; color: #58a6ff; }
header .meta { margin-top: 6px; font-size: 13px; color: #8b949e; }
main { padding: 20px 28px 60px; }
h2 { margin: 34px 0 4px; font-size: 15px; color: #79c0ff; border-bottom: 1px solid #21262d; padding-bottom: 6px; }
h3 { margin: 20px 0 2px; font-size: 14px; color: #e6edf3; }
.note { font-size: 12.5px; color: #8b949e; margin: 2px 0 10px; }
.count { color: #3fb950; font-weight: 600; }
table { border-collapse: collapse; width: 100%; font-size: 12.5px; margin-bottom: 8px; display: block; overflow-x: auto; }
th, td { border: 1px solid #21262d; padding: 5px 9px; text-align: left; white-space: nowrap; }
th { background: #161b22; color: #8b949e; position: sticky; top: 0; }
tr:nth-child(even) td { background: #0f141a; }
.trunc { color: #d29922; font-size: 12px; }
footer { padding: 16px 28px; color: #8b949e; font-size: 12px; border-top: 1px solid #21262d; }
'@

function ConvertTo-HtmlTable {
    param([object[]]$Rows)
    if (-not $Rows -or $Rows.Count -eq 0) { return '<p class="note">No rows.</p>' }
    $cols = $Rows[0].PSObject.Properties.Name
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $cols) { [void]$sb.Append('<th>' + [System.Net.WebUtility]::HtmlEncode([string]$c) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $val = $row.$c
            $text = if ($null -eq $val) { '' } else { [string]$val }
            [void]$sb.Append('<td>' + [System.Net.WebUtility]::HtmlEncode($text) + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function New-HtmlReport {
    if ($script:Session.Sections.Count -eq 0) { Write-Warn '  No results collected this session yet.'; return }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.Append('<title>MSAT Report - ' + [System.Net.WebUtility]::HtmlEncode($script:Session.Customer) + '</title>')
    [void]$sb.Append('<style>' + $script:ReportCss + '</style></head><body>')
    [void]$sb.Append('<header><h1>Mifune''s Sysadmin Toolkit</h1>')
    [void]$sb.Append('<div class="meta">Client: <b>' + [System.Net.WebUtility]::HtmlEncode($script:Session.Customer) + '</b>')
    [void]$sb.Append(' &nbsp;·&nbsp; Session ' + $script:Session.Stamp)
    [void]$sb.Append(' &nbsp;·&nbsp; Generated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '</div></header><main>')

    foreach ($cat in ($script:Session.Sections | Group-Object Category)) {
        [void]$sb.Append('<h2>' + [System.Net.WebUtility]::HtmlEncode($cat.Name) + '</h2>')
        foreach ($s in $cat.Group) {
            [void]$sb.Append('<h3>' + [System.Net.WebUtility]::HtmlEncode($s.Title))
            [void]$sb.Append(' <span class="count">(' + $s.Count + ' rows)</span></h3>')
            if ($s.Note) { [void]$sb.Append('<div class="note">' + [System.Net.WebUtility]::HtmlEncode($s.Note) + '</div>') }
            [void]$sb.Append((ConvertTo-HtmlTable -Rows $s.Rows))
            if ($s.Truncated) { [void]$sb.Append('<div class="trunc">Table truncated to first 500 rows; full data in ' + [System.Net.WebUtility]::HtmlEncode([IO.Path]::GetFileName($s.Csv)) + '</div>') }
        }
    }
    [void]$sb.Append('</main><footer>Generated by MSAT. Handle in line with the client engagement scope.</footer></body></html>')

    $path = Join-Path $script:Session.OutDir "MSAT_Report_$($script:Session.Customer -replace '[\\/:*?""<>|]','_')_$($script:Session.Stamp).html"
    $sb.ToString() | Out-File -FilePath $path -Encoding UTF8
    Write-Good "  Report written -> $path"
    if (Confirm-Action '  Open it now?') { Invoke-Item $path }
}

#endregion

#region Utilities and main

function Show-SessionInfo {
    Write-Head '  Session'
    Write-Info  "    Client:    $($script:Session.Customer)"
    Write-Info  "    Output:    $($script:Session.OutDir)"
    Write-Info  "    Sections:  $($script:Session.Sections.Count) collected"
    Write-Info  "    Elevated:  $(if (Test-Elevation) { 'Yes' } else { 'No - some checks need admin' })"
    Write-Info  "    PS:        $($PSVersionTable.PSVersion)"
}

function Invoke-UtilityMenu {
    Invoke-Menu -Title 'Utilities' -Color Gray -Items @(
        New-MenuItem 1 'Generate HTML report'      { New-HtmlReport }
        New-MenuItem 2 'Open output folder'         { Invoke-Item $script:Session.OutDir }
        New-MenuItem 3 'Session / elevation info'   { Show-SessionInfo }
    )
}

function Start-MsatSession {
    $script:Session.OutDir = Join-Path $OutputRoot ("{0}_{1}" -f ($Customer -replace '[\\/:*?"<>|]', '_'), $script:Session.Stamp)
    New-Item -Path $script:Session.OutDir -ItemType Directory -Force | Out-Null
    $transcript = Join-Path $script:Session.OutDir "MSAT_transcript.log"
    try { Start-Transcript -Path $transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
}

function Stop-MsatSession {
    if ($script:Session.Sections.Count -gt 0) {
        Write-Info ''
        if (Confirm-Action '  Write HTML report before exit?') { New-HtmlReport }
    }
    try { Stop-Transcript | Out-Null } catch {}
}

function Show-MainMenu {
    $items = @(
        @('1', 'Active Directory'), @('2', 'Investigation'), @('3', 'Endpoint / Health'),
        @('4', 'Network & Inventory'), @('5', 'Microsoft 365 / Entra'), @('6', 'Utilities & Report')
    )
    while ($true) {
        Show-Banner
        Write-Host ''
        foreach ($it in $items) {
            Write-Host '   [' -ForegroundColor DarkGray -NoNewline
            Write-Host $it[0] -ForegroundColor $script:BrandInk -NoNewline
            Write-Host ']  ' -ForegroundColor DarkGray -NoNewline
            Write-Host $it[1] -ForegroundColor White
        }
        Write-Host '   [Q]  Quit' -ForegroundColor DarkGray
        Write-Host ''
        $sel = (Read-Host '  Select').Trim().ToUpper()
        switch ($sel) {
            '1' { Invoke-ADMenu }
            '2' { Invoke-InvestigationMenu }
            '3' { Invoke-EndpointMenu }
            '4' { Invoke-NetworkMenu }
            '5' { Invoke-365Menu }
            '6' { Invoke-UtilityMenu }
            'Q' { return }
            default {}
        }
    }
}

Start-MsatSession
if (-not (Test-Elevation)) {
    Write-Warn '  Not running elevated - some checks (event logs, VSS, local admins) may be limited.'
    Start-Sleep -Seconds 1
}
try { Show-MainMenu } finally { Stop-MsatSession }

#endregion
