#requires -Version 5.1
# Module loading handled at runtime to avoid hard #requires failures.

[CmdletBinding(DefaultParameterSetName = 'None')]
param(
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,
    [Parameter(ParameterSetName = 'List')]
    [ValidateSet('All', 'OU', 'ServerList')]
    [string]$ListScope = 'All',
    [Parameter(ParameterSetName = 'List')]
    [string]$ListOU,
    [Parameter(ParameterSetName = 'List')]
    [string[]]$ListServerList,
    [Parameter(ParameterSetName = 'List')]
    [string]$ListOutputDirectory = '.\output',
    [Parameter(ParameterSetName = 'List')]
    [switch]$ColorizeRows = $true,
    [Parameter(ParameterSetName = 'Change', Mandatory)]
    [string[]]$Forwarders,
    [Parameter(ParameterSetName = 'Change')]
    [ValidateSet('Replace', 'Add', 'Remove')]
    [string]$Action = 'Replace',
    [Parameter(ParameterSetName = 'Change')]
    [ValidateSet('All', 'OU', 'ServerList')]
    [string]$Scope = 'All',
    [Parameter(ParameterSetName = 'Change')]
    [string]$OU,
    [Parameter(ParameterSetName = 'Change')]
    [string[]]$ServerList,
    [Parameter(ParameterSetName = 'Change')]
    [switch]$DryRun,
    [Parameter(ParameterSetName = 'Change')]
    [int]$Limit,
    [Parameter(ParameterSetName = 'Change')]
    [int]$MaxFailurePct = 50,
    [Parameter(ParameterSetName = 'Change')]
    [string]$MaintenanceWindow,
    [Parameter(ParameterSetName = 'Change')]
    [string]$ChangeOutputDirectory = '.\output',
    [switch]$InstallPrereqs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ModuleCapabilityName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    switch ($Name) {
        'ActiveDirectory' { 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0' }
        'DnsServer' { 'Rsat.Dns.Tools~~~~0.0.1.0' }
        default { $null }
    }
}

function Ensure-ModuleLoaded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$InstallPrereqs
    )

    if (Get-Module -Name $Name) {
        return
    }

    $available = Get-Module -ListAvailable -Name $Name
    if (-not $available) {
        $capability = Get-ModuleCapabilityName -Name $Name
        if ($InstallPrereqs -and $capability) {
            try {
                Add-WindowsCapability -Online -Name $capability -ErrorAction Stop | Out-Null
            } catch {
                throw "Required module '$Name' not found and installation failed. Run PowerShell as admin and install $capability. Error: $($_.Exception.Message)"
            }

            $available = Get-Module -ListAvailable -Name $Name
        }
    }

    if (-not $available) {
        $hint = if ($Name -eq 'ActiveDirectory') {
            'Install RSAT: Active Directory module (e.g., Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0).'
        } elseif ($Name -eq 'DnsServer') {
            'Install RSAT: DNS Server tools (e.g., Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0).'
        } else {
            'Install the required module and try again.'
        }

        throw "Required module '$Name' not found. $hint"
    }

    Import-Module -Name $Name -ErrorAction Stop
}

Ensure-ModuleLoaded -Name 'ActiveDirectory' -InstallPrereqs:$InstallPrereqs
Ensure-ModuleLoaded -Name 'DnsServer' -InstallPrereqs:$InstallPrereqs

function New-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [hashtable]$Data
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level     = $Level
        message   = $Message
        data      = $Data
    }

    $entry | ConvertTo-Json -Depth 8 -Compress
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [hashtable]$Data
    )

    $line = New-LogEntry -Level $Level -Message $Message -Data $Data
    Add-Content -Path $Path -Value $line
}

function Get-DnsServerCandidates {
    [CmdletBinding()]
    param(
        [ValidateSet('DCOnly', 'OU', 'CSV', 'Hybrid')]
        [string]$Mode = 'Hybrid',
        [string]$OU,
        [string]$CsvPath
    )

    $candidates = New-Object System.Collections.Generic.HashSet[string]

    if ($Mode -in @('DCOnly', 'Hybrid')) {
        $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
        foreach ($dc in $dcs) {
            [void]$candidates.Add($dc.ToLowerInvariant())
        }
    }

    if ($Mode -in @('OU', 'Hybrid') -and $OU) {
        $ouComputers = Get-ADComputer -SearchBase $OU -Filter * -Properties DNSHostName |
            Where-Object { $_.DNSHostName } |
            Select-Object -ExpandProperty DNSHostName
        foreach ($name in $ouComputers) {
            [void]$candidates.Add($name.ToLowerInvariant())
        }
    }

    if ($Mode -in @('CSV', 'Hybrid') -and $CsvPath) {
        $csvItems = Import-Csv -Path $CsvPath
        foreach ($item in $csvItems) {
            if ($item.Name) {
                [void]$candidates.Add($item.Name.ToLowerInvariant())
            }
        }
    }

    $candidates | Sort-Object
}

function Test-DnsServerAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    $result = [ordered]@{
        ComputerName = $ComputerName
        DnsResolvable = $false
        WinRM         = $false
        DnsService    = $false
        Error         = $null
    }

    try {
        [void][System.Net.Dns]::GetHostEntry($ComputerName)
        $result.DnsResolvable = $true
    } catch {
        $result.Error = $_.Exception.Message
        return [pscustomobject]$result
    }

    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        $result.WinRM = $true
    } catch {
        $result.Error = $_.Exception.Message
        return [pscustomobject]$result
    }

    try {
        $service = Get-Service -ComputerName $ComputerName -Name 'DNS' -ErrorAction Stop
        $result.DnsService = ($service.Status -ne 'Stopped')
    } catch {
        $result.Error = $_.Exception.Message
    }

    [pscustomobject]$result
}

function Get-DnsForwardersState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    $state = [ordered]@{
        ComputerName      = $ComputerName
        Forwarders        = @()
        UseRootHint       = $null
        TimeoutSec        = $null
        Status            = 'Unknown'
        Error             = $null
        Timestamp         = (Get-Date).ToString('o')
    }

    try {
        $forwarders = Get-DnsServerForwarder -ComputerName $ComputerName -ErrorAction Stop
        $state.Forwarders = @($forwarders.IPAddress.IPAddressToString)
        $state.UseRootHint = $forwarders.UseRootHint
        $state.TimeoutSec = $forwarders.Timeout
        $state.Status = 'OK'
    } catch {
        $state.Status = 'Unreachable'
        $state.Error = $_.Exception.Message
    }

    [pscustomobject]$state
}

function Get-ComputerSite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    try {
        $dc = Get-ADDomainController -Identity $ComputerName -ErrorAction Stop
        if ($dc.Site) {
            return $dc.Site
        }
    } catch {
    }

    try {
        $output = & nltest /server:$ComputerName /dsgetsite 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            $site = ($output | Select-Object -First 1).Trim()
            if ($site) {
                return $site
            }
        }
    } catch {
    }

    $null
}

function Get-DnsForwarderDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Current,
        [Parameter(Mandatory)]
        [string[]]$Desired,
        [ValidateSet('Replace', 'Add', 'Remove')]
        [string]$Action
    )

    $currentSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Current) {
        if ($item) { [void]$currentSet.Add($item.ToLowerInvariant()) }
    }

    $desiredSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Desired) {
        if ($item) { [void]$desiredSet.Add($item.ToLowerInvariant()) }
    }

    switch ($Action) {
        'Replace' { $result = $desiredSet }
        'Add' {
            $result = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($item in $currentSet) { [void]$result.Add($item) }
            foreach ($item in $desiredSet) { [void]$result.Add($item) }
        }
        'Remove' {
            $result = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($item in $currentSet) { [void]$result.Add($item) }
            foreach ($item in $desiredSet) { [void]$result.Remove($item) }
        }
    }

    ,($result | Sort-Object)
}

function Set-DnsForwardersState {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter(Mandatory)]
        [string[]]$Forwarders
    )

    if ($PSCmdlet.ShouldProcess($ComputerName, 'Set DNS forwarders')) {
        Set-DnsServerForwarder -ComputerName $ComputerName -IPAddress $Forwarders -ErrorAction Stop | Out-Null
        $verify = Get-DnsServerForwarder -ComputerName $ComputerName -ErrorAction Stop
        @($verify.IPAddress.IPAddressToString)
    } else {
        @()
    }
}

function Export-Inventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [object[]]$Inventory
    )

    if (-not (Test-Path -Path $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $csvPath = Join-Path $Directory "inventory-$timestamp.csv"
    $jsonPath = Join-Path $Directory "inventory-$timestamp.json"

    $Inventory | Export-Csv -Path $csvPath -NoTypeInformation
    $Inventory | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath

    [pscustomobject]@{
        CsvPath  = $csvPath
        JsonPath = $jsonPath
    }
}

function Export-ChangeBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [hashtable]$Bundle
    )

    if (-not (Test-Path -Path $Directory)) {
        New-Item -ItemType Directory -Path $Directory | Out-Null
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $bundlePath = Join-Path $Directory "change-bundle-$timestamp.json"
    $Bundle | ConvertTo-Json -Depth 10 | Set-Content -Path $bundlePath
    $bundlePath
}

function Invoke-DnsForwarderList {
    [CmdletBinding()]
    param(
        [ValidateSet('All', 'OU', 'ServerList')]
        [string]$Scope = 'All',
        [string]$OU,
        [string[]]$ServerList,
        [string]$OutputDirectory = '.\output'
    )

    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    $logPath = Join-Path $OutputDirectory 'list.log'
    $targetServers = @()

    switch ($Scope) {
        'All' {
            $targetServers = Get-DnsServerCandidates -Mode 'Hybrid' -OU $OU
        }
        'OU' {
            if (-not $OU) { throw 'OU is required when Scope=OU.' }
            $targetServers = Get-DnsServerCandidates -Mode 'OU' -OU $OU
        }
        'ServerList' {
            if (-not $ServerList) { throw 'ServerList is required when Scope=ServerList.' }
            $targetServers = $ServerList
        }
    }

    $targetServers = $targetServers | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
    $targetServers = @($targetServers)

    Write-Log -Path $logPath -Level Info -Message 'List started' -Data @{
        user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        domain = (Get-ADDomain).DNSRoot
        scope = $Scope
        count = $targetServers.Count
    }

    $results = foreach ($server in $targetServers) {
        Get-DnsForwardersState -ComputerName $server
    }

    Write-Log -Path $logPath -Level Info -Message 'List completed' -Data @{
        count = $results.Count
    }

    $results
}

function Invoke-DnsForwarderInventory {
    [CmdletBinding()]
    param(
        [ValidateSet('DCOnly', 'OU', 'CSV', 'Hybrid')]
        [string]$Mode = 'Hybrid',
        [string]$OU,
        [string]$CsvPath,
        [string]$OutputDirectory = '.\output'
    )

    $logPath = Join-Path $OutputDirectory 'inventory.log'
    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    Write-Log -Path $logPath -Level Info -Message 'Inventory started' -Data @{
        user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        domain = (Get-ADDomain).DNSRoot
        mode = $Mode
    }

    $candidates = Get-DnsServerCandidates -Mode $Mode -OU $OU -CsvPath $CsvPath
    $inventory = @()

    foreach ($server in $candidates) {
        $access = Test-DnsServerAccess -ComputerName $server
        if (-not $access.DnsService) {
            $inventory += [pscustomobject]@{
                ComputerName = $server
                Status = 'Skipped'
                Forwarders = @()
                UseRootHint = $null
                TimeoutSec = $null
                Timestamp = (Get-Date).ToString('o')
                Error = $access.Error
            }
            continue
        }

        $inventory += Get-DnsForwardersState -ComputerName $server
    }

    $paths = Export-Inventory -Directory $OutputDirectory -Inventory $inventory

    Write-Log -Path $logPath -Level Info -Message 'Inventory completed' -Data @{
        count = $inventory.Count
        csv = $paths.CsvPath
        json = $paths.JsonPath
    }

    $paths
}

function Invoke-DnsForwarderChange {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string[]]$Forwarders,
        [ValidateSet('Replace', 'Add', 'Remove')]
        [string]$Action = 'Replace',
        [ValidateSet('All', 'OU', 'ServerList')]
        [string]$Scope = 'All',
        [string]$OU,
        [string[]]$ServerList,
        [switch]$DryRun,
        [int]$Limit,
        [int]$MaxFailurePct = 50,
        [string]$MaintenanceWindow,
        [string]$OutputDirectory = '.\output'
    )

    if ($MaintenanceWindow) {
        $windowParts = $MaintenanceWindow -split '-'
        if ($windowParts.Count -ne 2) {
            throw 'MaintenanceWindow must be in HH:mm-HH:mm format.'
        }
        $now = Get-Date
        $start = [datetime]::ParseExact($windowParts[0], 'HH:mm', $null)
        $end = [datetime]::ParseExact($windowParts[1], 'HH:mm', $null)
        $start = Get-Date -Hour $start.Hour -Minute $start.Minute -Second 0
        $end = Get-Date -Hour $end.Hour -Minute $end.Minute -Second 0
        if ($end -lt $start) { $end = $end.AddDays(1) }
        if ($now -lt $start -or $now -gt $end) {
            throw "Current time is outside maintenance window ($MaintenanceWindow)."
        }
    }

    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    $logPath = Join-Path $OutputDirectory 'change.log'
    $targetServers = @()

    switch ($Scope) {
        'All' {
            $targetServers = Get-DnsServerCandidates -Mode 'Hybrid' -OU $OU
        }
        'OU' {
            if (-not $OU) { throw 'OU is required when Scope=OU.' }
            $targetServers = Get-DnsServerCandidates -Mode 'OU' -OU $OU
        }
        'ServerList' {
            if (-not $ServerList) { throw 'ServerList is required when Scope=ServerList.' }
            $targetServers = $ServerList
        }
    }

    $targetServers = $targetServers | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique
    if ($Limit -and $Limit -gt 0) {
        $targetServers = $targetServers | Select-Object -First $Limit
    }
    $targetServers = @($targetServers)

    Write-Log -Path $logPath -Level Info -Message 'Change started' -Data @{
        user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        domain = (Get-ADDomain).DNSRoot
        action = $Action
        forwarders = $Forwarders
        scope = $Scope
        count = $targetServers.Count
        dryRun = [bool]$DryRun
    }

    $results = @()
    $failures = 0

    foreach ($server in $targetServers) {
        $current = Get-DnsForwardersState -ComputerName $server
        if ($current.Status -ne 'OK') {
            $failures++
            $results += [pscustomobject]@{
                ComputerName = $server
                Status = 'Failed'
                Error = $current.Error
                Before = $current.Forwarders
                After = @()
            }
            continue
        }

        $desired = Get-DnsForwarderDelta -Current $current.Forwarders -Desired $Forwarders -Action $Action
        $diff = [pscustomobject]@{
            ComputerName = $server
            Before = $current.Forwarders
            After = $desired
            Action = $Action
        }

        if ($DryRun) {
            $results += [pscustomobject]@{
                ComputerName = $server
                Status = 'DryRun'
                Error = $null
                Before = $current.Forwarders
                After = $desired
            }
            continue
        }

        try {
            $after = Set-DnsForwardersState -ComputerName $server -Forwarders $desired
            $results += [pscustomobject]@{
                ComputerName = $server
                Status = 'Success'
                Error = $null
                Before = $current.Forwarders
                After = $after
            }
        } catch {
            $failures++
            $results += [pscustomobject]@{
                ComputerName = $server
                Status = 'Failed'
                Error = $_.Exception.Message
                Before = $current.Forwarders
                After = @()
            }
        }

        $failurePct = if ($targetServers.Count -gt 0) { [math]::Round(($failures / $targetServers.Count) * 100, 2) } else { 0 }
        if ($failurePct -ge $MaxFailurePct) {
            Write-Log -Path $logPath -Level Warning -Message 'Failure threshold reached; stopping further changes' -Data @{
                failurePct = $failurePct
                maxFailurePct = $MaxFailurePct
            }
            break
        }
    }

    $bundle = @{
        timestamp = (Get-Date).ToString('o')
        action = $Action
        forwarders = $Forwarders
        results = $results
    }

    $bundlePath = Export-ChangeBundle -Directory $OutputDirectory -Bundle $bundle

    Write-Log -Path $logPath -Level Info -Message 'Change completed' -Data @{
        total = $targetServers.Count
        failures = $failures
        bundle = $bundlePath
    }

    [pscustomobject]@{
        BundlePath = $bundlePath
        Results = $results
    }
}

function Invoke-DnsForwarderRollback {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string]$FromBundle,
        [string]$OutputDirectory = '.\output'
    )

    $bundle = Get-Content -Path $FromBundle -Raw | ConvertFrom-Json

    if (-not (Test-Path -Path $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    }

    $logPath = Join-Path $OutputDirectory 'rollback.log'
    Write-Log -Path $logPath -Level Info -Message 'Rollback started' -Data @{
        bundle = $FromBundle
    }

    $results = @()

    foreach ($item in $bundle.results) {
        if ($item.Status -ne 'Success') { continue }

        try {
            if ($PSCmdlet.ShouldProcess($item.ComputerName, 'Rollback DNS forwarders')) {
                $null = Set-DnsServerForwarder -ComputerName $item.ComputerName -IPAddress $item.Before -ErrorAction Stop
            }
            $results += [pscustomobject]@{
                ComputerName = $item.ComputerName
                Status = 'RolledBack'
                Error = $null
            }
        } catch {
            $results += [pscustomobject]@{
                ComputerName = $item.ComputerName
                Status = 'Failed'
                Error = $_.Exception.Message
            }
        }
    }

    Write-Log -Path $logPath -Level Info -Message 'Rollback completed' -Data @{
        total = $results.Count
    }

    $results
}

if ($List) {
    $results = Invoke-DnsForwarderList -Scope $ListScope -OU $ListOU -ServerList $ListServerList -OutputDirectory $ListOutputDirectory
    $displayRows = $results |
        Sort-Object -Property ComputerName |
        Select-Object -Property @{ Name = 'Site'; Expression = { Get-ComputerSite -ComputerName $_.ComputerName } },
            ComputerName,
            @{ Name = 'Forwarders'; Expression = { $_.Forwarders -join ', ' } }

    if ($ColorizeRows) {
        $siteWidth = (($displayRows | ForEach-Object { $siteValue = if ($_.Site) { $_.Site } else { '' }; $siteValue.Length } | Measure-Object -Maximum).Maximum)
        $nameWidth = (($displayRows | ForEach-Object { $_.ComputerName.Length } | Measure-Object -Maximum).Maximum)
        $siteWidth = [math]::Max($siteWidth, 'Site'.Length)
        $nameWidth = [math]::Max($nameWidth, 'ComputerName'.Length)

        $header = ('{0}  {1}  {2}' -f 'Site'.PadRight($siteWidth), 'ComputerName'.PadRight($nameWidth), 'Forwarders')
        Write-Host $header -ForegroundColor Cyan
        Write-Host ('-' * $header.Length) -ForegroundColor Cyan

        $rowIndex = 0
        foreach ($row in $displayRows) {
            $bgColor = if (($rowIndex % 2) -eq 0) { 'DarkGray' } else { 'Black' }
            $siteValue = if ($row.Site) { $row.Site } else { '' }
            $line = ('{0}  {1}  {2}' -f $siteValue.PadRight($siteWidth), $row.ComputerName.PadRight($nameWidth), $row.Forwarders)
            Write-Host $line -ForegroundColor White -BackgroundColor $bgColor
            $rowIndex++
        }
    } else {
        $displayRows | Format-Table -AutoSize -Wrap
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Change') {
    Invoke-DnsForwarderChange -Forwarders $Forwarders -Action $Action -Scope $Scope -OU $OU -ServerList $ServerList -DryRun:$DryRun -Limit $Limit -MaxFailurePct $MaxFailurePct -MaintenanceWindow $MaintenanceWindow -OutputDirectory $ChangeOutputDirectory
}

<#[
Example usage:

Invoke-DnsForwarderInventory -Mode Hybrid -OU "OU=DNS Servers,DC=contoso,DC=com" -OutputDirectory .\output

Invoke-DnsForwarderChange -Forwarders @('1.1.1.1','8.8.8.8') -Action Replace -Scope OU -OU "OU=DNS Servers,DC=contoso,DC=com" -DryRun

Invoke-DnsForwarderChange -Forwarders @('1.1.1.1','8.8.8.8') -Action Replace -Scope ServerList -ServerList @('dns01.contoso.com','dns02.contoso.com') -Confirm

Invoke-DnsForwarderRollback -FromBundle .\output\change-bundle-20250101-120000.json -Confirm

.\Manage-DnsForwarders.ps1 -List -ListScope ServerList -ListServerList @('dns01.contoso.com','dns02.contoso.com')
#>
