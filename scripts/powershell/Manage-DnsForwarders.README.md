# Manage-DnsForwarders.ps1

Inventory and manage DNS forwarders across Active Directory DNS servers with guardrails, logging, and rollback support.

## Requirements

- Windows PowerShell 5.1+
- RSAT modules: `ActiveDirectory`, `DnsServer`
- Permissions:
  - AD read access for discovery
  - DNS admin rights to change forwarders remotely
- Network access:
  - DNS resolution to target servers
  - WinRM enabled for remote queries

## Script location

`scripts/powershell/Manage-DnsForwarders.ps1`

## Discovery modes

The script discovers DNS server candidates via AD. You can choose a discovery mode:

- `DCOnly`: Domain controllers only
- `OU`: Computers in a specified OU
- `CSV`: Names from a CSV file
- `Hybrid` (default): DCs + optional OU + optional CSV

## Inventory

Creates a forwarder inventory and exports CSV + JSON, plus a log file.

### Examples

```powershell
.\Manage-DnsForwarders.ps1
Invoke-DnsForwarderInventory -Mode Hybrid -OU "OU=DNS Servers,DC=contoso,DC=com" -OutputDirectory .\output
```

Outputs:

- `output\inventory-<timestamp>.csv`
- `output\inventory-<timestamp>.json`
- `output\inventory.log`

## Change forwarders

Supports Replace/Add/Remove actions with guardrails and rollback bundles.

### Parameters

- `-Forwarders`: Array of IPs
- `-Action`: `Replace` (default), `Add`, `Remove`
- `-Scope`: `All`, `OU`, `ServerList`
- `-DryRun`: Show diffs only, no changes
- `-Limit`: Pilot to first N targets
- `-MaxFailurePct`: Stop if failure % reached (default 50)
- `-MaintenanceWindow`: `HH:mm-HH:mm`
- `-OutputDirectory`: Log/bundle output path

### Dry run

```powershell
.\Manage-DnsForwarders.ps1
Invoke-DnsForwarderChange -Forwarders @('1.1.1.1','8.8.8.8') -Action Replace -Scope OU -OU "OU=DNS Servers,DC=contoso,DC=com" -DryRun
```

### Apply changes

```powershell
.\Manage-DnsForwarders.ps1
Invoke-DnsForwarderChange -Forwarders @('1.1.1.1','8.8.8.8') -Action Replace -Scope ServerList -ServerList @('dns01.contoso.com','dns02.contoso.com') -Confirm
```

Outputs:

- `output\change-bundle-<timestamp>.json`
- `output\change.log`

## Rollback

Use the change bundle to restore forwarders to their prior values.

```powershell
.\Manage-DnsForwarders.ps1
Invoke-DnsForwarderRollback -FromBundle .\output\change-bundle-20250101-120000.json -Confirm
```

Outputs:

- `output\rollback.log`

## CSV input format

If you use `-Mode CSV`, provide a CSV with a `Name` column.

```csv
Name
DNS01.contoso.com
DNS02.contoso.com
```

## Operational tips

- Start with `-DryRun` and a small `-Limit`.
- Use a maintenance window for production changes.
- Store change bundles in a restricted location.

## Troubleshooting

- `Unreachable` in inventory: DNS resolution, WinRM access, or permissions issue.
- `Skipped`: DNS service not running or not found on the host.

## Notes

- The script uses `Get-DnsServerForwarder` and `Set-DnsServerForwarder` for read/verify/change operations.
- IPv6 forwarders are supported if the target servers accept them.
