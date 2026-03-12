<#
.SYNOPSIS
Creates a Kerberos keytab for a web service such as Keycloak.

.DESCRIPTION
This script is designed for offline Active Directory environments and is intended
to run on a Domain Controller or on a Windows system with RSAT / AD DS tools installed.

It:
- Prompts for the service account
- Prompts for the service hostname (the exact FQDN users browse to)
- Detects the AD domain/realm automatically when possible
- Creates the HTTP SPN if requested
- Checks for duplicate SPNs
- Prompts securely for the service account password
- Generates a keytab using ktpass.exe

The script is domain-agnostic and suitable for reuse across multiple customer domains.

.NOTES
Recommended to run in an elevated PowerShell session.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CommandName
    )
    try {
        return [bool](Get-Command $CommandName -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Get-DomainInfo {
    $result = [ordered]@{
        DomainFqdn = $null
        NetBIOS    = $null
        Realm      = $null
    }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.PartOfDomain -and $cs.Domain) {
            $result.DomainFqdn = $cs.Domain
            $result.Realm = $cs.Domain.ToUpperInvariant()
        }
    }
    catch {}

    try {
        $adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        if ($adDomain.Name) {
            $result.DomainFqdn = $adDomain.Name
            $result.Realm = $adDomain.Name.ToUpperInvariant()
        }
    }
    catch {}

    try {
        $root = [ADSI]"LDAP://RootDSE"
        $context = $root.rootDomainNamingContext
        if ($context) {
            $fqdn = ($context -replace ',DC=', '.') -replace '^DC=', ''
            if ($fqdn) {
                $result.DomainFqdn = $fqdn
                $result.Realm = $fqdn.ToUpperInvariant()
            }
        }
    }
    catch {}

    try {
        $adsi = [ADSI]"WinNT://$env:USERDOMAIN"
        if ($adsi.Name) {
            $result.NetBIOS = $adsi.Name
        }
    }
    catch {
        if ($env:USERDOMAIN) {
            $result.NetBIOS = $env:USERDOMAIN
        }
    }

    [pscustomobject]$result
}

function Prompt-NonEmpty {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt
    )

    do {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-WarnMsg "A value is required."
    } while ($true)
}

function Prompt-YesNo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }

    do {
        $answer = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
            default { Write-WarnMsg "Enter y or n." }
        }
    } while ($true)
}

function Get-PlainTextFromSecureString {
    param(
        [Parameter(Mandatory=$true)]
        [Security.SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Confirm-OutputDirectory {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        Write-Info "Creating directory: $dir"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Clear-Host
Write-Host "Kerberos Keytab Creation Utility" -ForegroundColor White
Write-Host "Offline-capable | Domain-agnostic | Intended for Keycloak and other HTTP services" -ForegroundColor Gray
Write-Host ""

if (-not (Test-CommandExists -CommandName 'setspn.exe')) {
    throw "setspn.exe was not found. Install RSAT AD DS tools or run this on a Domain Controller."
}
if (-not (Test-CommandExists -CommandName 'ktpass.exe')) {
    throw "ktpass.exe was not found. Install RSAT AD DS tools or run this on a Domain Controller."
}

$domainInfo = Get-DomainInfo

Write-Info "Detected domain information:"
Write-Host ("  Domain FQDN : {0}" -f $(if ($domainInfo.DomainFqdn) { $domainInfo.DomainFqdn } else { '<not detected>' })) -ForegroundColor Gray
Write-Host ("  NetBIOS     : {0}" -f $(if ($domainInfo.NetBIOS) { $domainInfo.NetBIOS } else { '<not detected>' })) -ForegroundColor Gray
Write-Host ("  Realm       : {0}" -f $(if ($domainInfo.Realm) { $domainInfo.Realm } else { '<not detected>' })) -ForegroundColor Gray
Write-Host ""

$serviceAccountInput = Prompt-NonEmpty -Prompt "Enter the AD service account (examples: svc-keycloak or CONTOSO\svc-keycloak)"
$keycloakHostFqdn = Prompt-NonEmpty -Prompt "Enter the service hostname/FQDN users browse to (example: keycloak.example.com)"

$useDetectedDomain = $true
if (-not $domainInfo.DomainFqdn) {
    $useDetectedDomain = $false
}
else {
    $useDetectedDomain = Prompt-YesNo -Prompt ("Use detected domain '{0}'?" -f $domainInfo.DomainFqdn) -Default $true
}

if ($useDetectedDomain) {
    $domainFqdn = $domainInfo.DomainFqdn
}
else {
    $domainFqdn = Prompt-NonEmpty -Prompt "Enter the AD domain FQDN (example: contoso.local)"
}

$realm = $domainFqdn.ToUpperInvariant()

$defaultOutput = Join-Path $env:SystemDrive 'temp\keycloak.keytab'
$outputPath = Read-Host "Enter output path for the keytab file [default = $defaultOutput]"
if ([string]::IsNullOrWhiteSpace($outputPath)) {
    $outputPath = $defaultOutput
}

$crypto = Read-Host "Enter crypto type [default = AES256-SHA1] (valid: AES256-SHA1, AES128-SHA1, All)"
if ([string]::IsNullOrWhiteSpace($crypto)) {
    $crypto = 'AES256-SHA1'
}

$validCrypto = @('AES256-SHA1','AES128-SHA1','All')
if ($validCrypto -notcontains $crypto) {
    throw "Invalid crypto type '$crypto'. Valid values: $($validCrypto -join ', ')"
}

$spn = "HTTP/$keycloakHostFqdn"
$principal = "$spn@$realm"

Write-Host ""
Write-Host "Configuration Summary" -ForegroundColor White
Write-Host ("  Service account : {0}" -f $serviceAccountInput) -ForegroundColor Gray
Write-Host ("  Service host    : {0}" -f $keycloakHostFqdn) -ForegroundColor Gray
Write-Host ("  Domain FQDN     : {0}" -f $domainFqdn) -ForegroundColor Gray
Write-Host ("  Kerberos realm  : {0}" -f $realm) -ForegroundColor Gray
Write-Host ("  SPN             : {0}" -f $spn) -ForegroundColor Gray
Write-Host ("  Principal       : {0}" -f $principal) -ForegroundColor Gray
Write-Host ("  Output path     : {0}" -f $outputPath) -ForegroundColor Gray
Write-Host ("  Crypto          : {0}" -f $crypto) -ForegroundColor Gray
Write-Host ""

if (-not (Prompt-YesNo -Prompt "Continue?" -Default $true)) {
    Write-WarnMsg "Operation cancelled."
    exit 1
}

Write-Info "Checking for duplicate SPNs..."
$spnQueryOutput = & setspn.exe -Q $spn 2>&1
$spnQueryText = ($spnQueryOutput | Out-String)

if ($LASTEXITCODE -ne 0 -and $spnQueryText -notmatch 'No such SPN found') {
    Write-WarnMsg "setspn -Q returned a non-zero code. Output:"
    $spnQueryOutput | ForEach-Object { Write-Host $_ -ForegroundColor DarkYellow }
}

$existingMatches = @()
foreach ($line in $spnQueryOutput) {
    if ($line -match '^CN=') {
        $existingMatches += $line.Trim()
    }
}

if ($existingMatches.Count -gt 1) {
    Write-Fail "Multiple objects already have the SPN '$spn'. Resolve duplicates before continuing."
    $existingMatches | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

$registerSpn = Prompt-YesNo -Prompt "Create or update the SPN on the service account now?" -Default $true
if ($registerSpn) {
    Write-Info "Registering SPN '$spn' on account '$serviceAccountInput'..."
    & setspn.exe -S $spn $serviceAccountInput
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register SPN. Verify permissions and account name."
    }
    Write-Ok "SPN registered successfully."
}
else {
    Write-WarnMsg "Skipping SPN registration."
}

$securePassword = Read-Host "Enter the service account password" -AsSecureString
$plainPassword = Get-PlainTextFromSecureString -SecureString $securePassword

Confirm-OutputDirectory -Path $outputPath

Write-Info "Generating keytab..."
$ktpassArgs = @(
    '-princ', $principal,
    '-mapuser', $serviceAccountInput,
    '-crypto', $crypto,
    '-ptype', 'KRB5_NT_PRINCIPAL',
    '-pass', $plainPassword,
    '-out', $outputPath
)

try {
    & ktpass.exe @ktpassArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ktpass.exe failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $outputPath)) {
        throw "ktpass.exe did not produce the output file."
    }

    Write-Ok "Keytab created successfully."
    Write-Host ""
    Write-Host "Keytab file: $outputPath" -ForegroundColor Green
    Write-Host "Server principal: $principal" -ForegroundColor Green
    Write-Host ""
    Write-Host "Use that principal and the mounted keytab path in Keycloak." -ForegroundColor Gray
}
finally {
    if ($plainPassword) {
        $plainPassword = $null
    }
}
