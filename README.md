# Mifune's Sysadmin Toolkit (MSAT)

A single-file PowerShell field CLI for MSP and sysadmin work. It gives you a fast
read on a Windows environment for troubleshooting and investigation, and writes
every result to disk so you keep a record of what you found.

## What it covers

- **Active Directory** — inactive users, password age, locked-out accounts, privileged-group audit, stale computers, group membership, recently created accounts
- **Investigation** — logon activity, failed-logon analysis, account-lockout source tracing, account/group change events, persistence & autoruns, Sysmon, PowerShell script-block logging, a full local triage bundle
- **Endpoint / health** — health snapshot, pending reboot, Windows Update status, disk/SMART, BitLocker, certificate expiry, backup-agent status, local admins, winget upgrades
- **Network & inventory** — async ping sweep, CIM host inventory, network snapshot, port checks, domain/DNS health
- **Microsoft 365 / Entra** — tenant connect, user read-out, MFA-registration report, license usage, admin-role members, risky users, sign-in history

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Active Directory features need RSAT: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- Microsoft 365 features need the Graph SDK: `Install-Module Microsoft.Graph -Scope CurrentUser`
- Run elevated for event-log, VSS, and local-admin checks

Missing modules degrade gracefully — the tool tells you what to install rather than erroring out.

## Usage

```powershell
.\MSAT.ps1 -Customer "Client Name"
```

If scripts are blocked by execution policy, run it for that session only:

```powershell
powershell -ExecutionPolicy Bypass -File .\MSAT.ps1 -Customer "Client Name"
```

Navigate with the number keys; `B` goes back, `Q` quits.

## Output

Each run creates `Outputs\<Client>_<timestamp>\` containing:

- a CSV + JSON for every check you run
- a transcript of the session
- an optional self-contained HTML report (Utilities menu, or on exit) summarizing everything collected

## Notes

- **Read-only.** MSAT queries and reports; it does not modify AD objects, system configuration, or endpoints. It writes only to its own output folder.
- The script is stored as UTF-8 with a BOM so the header renders correctly on PowerShell 5.1 — keep the BOM if you re-save it.
- Use a modern console font (Consolas or Cascadia Code) so the header art displays.
