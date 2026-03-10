<#
.SYNOPSIS
  AD CS bootstrapper for closed lab environments (Standalone Root, Enterprise Root, Enterprise Subordinate).

.DESCRIPTION
  Installs and configures the AD CS Certification Authority role and (optionally) Web Enrollment,
  configures CRL/AIA distribution (HTTP retrieval + optional SMB publish + optional LDAP retrieval),
  and can import Enterprise OIDs + Certificate Templates from LDF files, then publish templates on the CA.

  Inputs can be provided by:
    - YAML config file (-ConfigPath)
    - CLI flags (limited)
    - Interactive prompts (if YAML not provided)

.NOTES
  - CAPolicy.inf is only consumed during CA installation (and CA cert renewal).
  - Run this script elevated (Administrator).
  - Enterprise CA installs require domain join + sufficient privileges (commonly Enterprise Admin).
  - For YAML parsing:
      * PowerShell 7+ supports ConvertFrom-Yaml (preferred).
      * On Windows PowerShell 5.1, vendor the 'powershell-yaml' module offline.

.LINK
  Install-AdcsCertificationAuthority:
    https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcscertificationauthority
  Install-AdcsWebEnrollment:
    https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcswebenrollment
  CDP/AIA configuration guidance:
    https://learn.microsoft.com/windows-server/networking/core-network-guide/cncg/server-certs/configure-the-cdp-and-aia-extensions-on-ca1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string]$ConfigPath,

  [ValidateSet('StandaloneRootCA','StandaloneSubordinateCA','EnterpriseRootCA','EnterpriseSubordinateCA')]
  [string]$CAType,

  [switch]$CreateDirectoryObjects,
  [switch]$PublishTemplates,

  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ---------- Logging / Guardrails ----------
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
  )
  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  switch ($Level) {
    'INFO'  { Write-Host "[$ts] [$Level]  $Message" }
    'OK'    { Write-Host "[$ts] [$Level]  $Message" -ForegroundColor Green }
    'WARN'  { Write-Host "[$ts] [$Level]  $Message" -ForegroundColor Yellow }
    'ERROR' { Write-Host "[$ts] [$Level]  $Message" -ForegroundColor Red }
  }
}

function Assert-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p  = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run elevated (Administrator)."
  }
}

function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    throw "Required module missing: $Name"
  }
  Import-Module $Name -ErrorAction Stop
}

function Ensure-WindowsFeature {
  param([Parameter(Mandatory)][string[]]$Name)
  foreach ($n in $Name) {
    $f = Get-WindowsFeature -Name $n
    if (-not $f) { throw "Windows feature not found: $n" }
    if (-not $f.Installed) {
      Write-Log "Installing Windows feature: $n"
      Install-WindowsFeature -Name $n -IncludeManagementTools | Out-Null
    } else {
      Write-Log "Windows feature already installed: $n"
    }
  }
}

function Test-DomainJoined {
  try {
    return (Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain
  } catch {
    return $false
  }
}
#endregion

#region ---------- YAML / Interactive ----------
function Import-YamlConfig {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path $Path)) { throw "ConfigPath not found: $Path" }
  $raw = Get-Content -Path $Path -Raw

  $cmd = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
  if ($cmd) {
    return ($raw | ConvertFrom-Yaml)
  }

  # Offline-friendly fallback: vendor powershell-yaml module
  $mod = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
  if (-not $mod) {
    throw "ConvertFrom-Yaml not available. Use PowerShell 7+ OR vendor the 'powershell-yaml' module offline."
  }

  Import-Module powershell-yaml -ErrorAction Stop
  return (ConvertFrom-Yaml -Yaml $raw)
}

function Prompt-Choice {
  param(
    [Parameter(Mandatory)][string]$Question,
    [Parameter(Mandatory)][string[]]$Options
  )
  Write-Host ""
  Write-Host $Question
  for ($i=0; $i -lt $Options.Count; $i++) {
    Write-Host "  [$($i+1)] $($Options[$i])"
  }
  do {
    $ans = Read-Host "Select 1-$($Options.Count)"
  } until ($ans -as [int] -and $ans -ge 1 -and $ans -le $Options.Count)
  return $Options[$ans-1]
}
#endregion

#region ---------- CAPolicy.inf ----------
function Write-CAPolicyInf {
  param([Parameter(Mandatory)][pscustomobject]$Config)

  $cap = $Config.capolicy
  if (-not $cap) {
    Write-Log "No 'capolicy' section; skipping CAPolicy.inf generation." 'WARN'
    return
  }

  $policyName = $cap.policyName
  $policyOid  = $cap.policyOid
  if (-not $policyName -or -not $policyOid) {
    throw "capolicy.policyName and capolicy.policyOid are required."
  }

  $notice = $cap.notice
  $cpsUrl = $cap.cpsUrl

  # Best practice: do not auto-publish default templates unless explicitly desired (Enterprise CAs).
  $loadDefaultTemplates = 0
  if ($Config.ca -and $Config.ca.loadDefaultTemplates -ne $null) {
    $loadDefaultTemplates = [int]$Config.ca.loadDefaultTemplates
  }

  $crlPeriod = $cap.crl.period
  $crlUnits  = $cap.crl.units
  $ovlPeriod = $cap.crl.overlapPeriod
  $ovlUnits  = $cap.crl.overlapUnits

  $lines = @()
  $lines += '[Version]'
  $lines += 'Signature="$Windows NT$"'
  $lines += ''
  $lines += '[PolicyStatementExtension]'
  $lines += "Policies=$policyName"
  $lines += ''
  $lines += "[$policyName]"
  $lines += "OID=$policyOid"
  if ($notice) { $lines += "Notice=""$notice""" }
  if ($cpsUrl)  { $lines += "URL=""$cpsUrl""" }
  $lines += ''
  $lines += '[Certsrv_Server]'
  $lines += "LoadDefaultTemplates=$loadDefaultTemplates"
  if ($crlPeriod -and $crlUnits) {
    $lines += "CRLPeriod=$crlPeriod"
    $lines += "CRLPeriodUnits=$crlUnits"
  }
  if ($ovlPeriod -and $ovlUnits) {
    $lines += "CRLOverlapPeriod=$ovlPeriod"
    $lines += "CRLOverlapUnits=$ovlUnits"
  }

  $path = Join-Path $env:WINDIR 'CAPolicy.inf'
  Write-Log "Writing CAPolicy.inf to $path"
  $lines -join "`r`n" | Set-Content -Path $path -Encoding Ascii -Force
}
#endregion

#region ---------- IIS + PKI share (publish target) ----------
function Ensure-PkiShareAndIis {
  param(
    [Parameter(Mandatory)][string]$ShareHost,     # e.g. losubca001
    [Parameter(Mandatory)][string]$ShareName,     # e.g. pki
    [Parameter(Mandatory)][string]$LocalPath      # e.g. C:\ProgramData\PKI
  )

  # Only manage share/IIS on the host that is supposed to own it
  $localShort = $env:COMPUTERNAME
  $localFqdn  = if ($env:USERDNSDOMAIN) { "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)" } else { $null }

  $match = $false
  foreach ($n in @($localShort,$localFqdn) | Where-Object { $_ }) {
    if ($n.ToLowerInvariant() -eq $ShareHost.ToLowerInvariant()) { $match = $true }
  }
  if (-not $match) {
    Write-Log "PKI share host '$ShareHost' is not local; skipping local share/IIS creation." 'INFO'
    return
  }

  Ensure-WindowsFeature -Name @('Web-Server')
  Ensure-Module -Name WebAdministration

  if (-not (Test-Path $LocalPath)) {
    Write-Log "Creating PKI folder: $LocalPath"
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
  }

  # NTFS permissions (tight)
  # - SYSTEM/Admins: Full
  # - Cert Publishers: Modify (CA can publish via its computer account membership)
  # - IIS_IUSRS: Read/Execute (serve files)
  Write-Log "Setting NTFS ACL on $LocalPath"
  $acl = Get-Acl $LocalPath
  $acl.SetAccessRuleProtection($true, $false) | Out-Null  # disable inheritance, strip inherited

  foreach ($r in @($acl.Access)) { $null = $acl.RemoveAccessRule($r) }

  $rules = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","ContainerInherit,ObjectInherit","None","Allow"),
    New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","ContainerInherit,ObjectInherit","None","Allow"),
    New-Object System.Security.AccessControl.FileSystemAccessRule("Cert Publishers","Modify","ContainerInherit,ObjectInherit","None","Allow"),
    New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS","ReadAndExecute","ContainerInherit,ObjectInherit","None","Allow")
  )
  foreach ($r in $rules) { $acl.AddAccessRule($r) | Out-Null }
  Set-Acl -Path $LocalPath -AclObject $acl

  # SMB Share
  $existing = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
  if (-not $existing) {
    Write-Log "Creating SMB share: \\$ShareHost\$ShareName -> $LocalPath"
    New-SmbShare -Name $ShareName -Path $LocalPath `
      -FullAccess "BUILTIN\Administrators" `
      -ChangeAccess "Cert Publishers" `
      -ReadAccess "Authenticated Users" | Out-Null
  } else {
    Write-Log "SMB share already exists: $ShareName"
  }

  # IIS vdir: /pki -> LocalPath
  $site = 'Default Web Site'
  $vdPath = "IIS:\Sites\$site\pki"
  if (-not (Test-Path $vdPath)) {
    Write-Log "Creating IIS virtual directory /pki -> $LocalPath"
    New-WebVirtualDirectory -Site $site -Name 'pki' -PhysicalPath $LocalPath | Out-Null
  } else {
    Write-Log "IIS virtual directory already exists: /pki"
  }

  # Delta CRLs often include '+'; allowDoubleEscaping avoids IIS request-filter breaks.
  $appcmd = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
  if (Test-Path $appcmd) {
    Write-Log "Setting allowDoubleEscaping=true for $site/pki"
    & $appcmd set config "$site/pki" -section:system.webServer/security/requestFiltering -allowDoubleEscaping:true /commit:apphost | Out-Null
  }

  # MIME types (avoid edge-case downloads)
  $mimeCrl = Get-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/staticContent/mimeMap[@fileExtension='.crl']" -name "." -ErrorAction SilentlyContinue
  if (-not $mimeCrl) {
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/staticContent" -name "." -value @{ fileExtension='.crl'; mimeType='application/pkix-crl' } | Out-Null
  }
  $mimeCrt = Get-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/staticContent/mimeMap[@fileExtension='.crt']" -name "." -ErrorAction SilentlyContinue
  if (-not $mimeCrt) {
    Add-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/staticContent" -name "." -value @{ fileExtension='.crt'; mimeType='application/x-x509-ca-cert' } | Out-Null
  }
}
#endregion

#region ---------- CDP/AIA distribution ----------
function Configure-CdpAiaDistribution {
  param(
    [Parameter(Mandatory)][string]$HttpBaseUrl,
    [Parameter()][string]$ShareHost,
    [Parameter()][string]$ShareName,
    [Parameter(Mandatory)][bool]$IncludeLdap,
    [Parameter(Mandatory)][bool]$PublishToShare
  )

  Ensure-Module -Name ADCSAdministration

  $http = $HttpBaseUrl.TrimEnd('/')

  # Deterministic config: clear, then set exactly what we want.
  Get-CACrlDistributionPoint | ForEach-Object { Remove-CACrlDistributionPoint -Uri $_.Uri -Confirm:$false -Force | Out-Null }
  Get-CAAuthorityInformationAccess | ForEach-Object { Remove-CAAuthorityInformationAccess -Uri $_.Uri -Confirm:$false -Force | Out-Null }

  # Publish locally (CertEnroll) regardless
  Add-CACrlDistributionPoint -Uri "$env:WINDIR\System32\CertSrv\CertEnroll\%3%8%9.crl" -PublishToServer -PublishDeltaToServer -Force | Out-Null
  Add-CAAuthorityInformationAccess -Uri "$env:WINDIR\System32\CertSrv\CertEnroll\%1_%3%4.crt" -PublishToServer -Force | Out-Null

  # Optional: publish to SMB share (your pattern). Use tokenized filenames for portability.
  if ($PublishToShare) {
    if (-not $ShareHost -or -not $ShareName) {
      throw "PublishToShare=true requires ShareHost and ShareName."
    }
    $unc  = "\\$ShareHost\$ShareName"
    $file = "file://$unc"

    Add-CACrlDistributionPoint -Uri "$file/%3%8%9.crl" -PublishToServer -PublishDeltaToServer -Force | Out-Null
    Add-CAAuthorityInformationAccess -Uri "$file/%1_%3%4.crt" -PublishToServer -Force | Out-Null
  }

  # Client retrieval endpoints (HTTP)
  Add-CACrlDistributionPoint -Uri "$http/%3%8%9.crl" -AddToCertificateCdp -AddToFreshestCrl -Force | Out-Null
  Add-CAAuthorityInformationAccess -Uri "$http/%1_%3%4.crt" -AddToCertificateAia -Force | Out-Null

  # Optional LDAP endpoints (enterprise friendly)
  if ($IncludeLdap) {
    Add-CACrlDistributionPoint -Uri "ldap:///CN=%7%8,CN=%2,CN=CDP,CN=Public Key Services,CN=Services,%6%10" -AddToCrlCdp -AddToCertificateCdp -Force | Out-Null
    Add-CAAuthorityInformationAccess -Uri "ldap:///CN=%7,CN=AIA,CN=Public Key Services,CN=Services,%6%11" -AddToCertificateAia -Force | Out-Null
  }

  Restart-Service CertSvc -Force
  & certutil.exe -crl | Out-Null
}
#endregion

#region ---------- Web Enrollment ----------
function Install-WebEnrollment {
  param([Parameter(Mandatory)][string]$CACommonName)

  Ensure-Module -Name ADCSDeployment
  Ensure-WindowsFeature -Name @('ADCS-Web-Enrollment','Web-Server')

  $caConfig = "$env:COMPUTERNAME\$CACommonName"
  Write-Log "Installing AD CS Web Enrollment (CAConfig=$caConfig)"
  Install-AdcsWebEnrollment -CAConfig $caConfig -Force
}
#endregion

#region ---------- Baseline CA hardening ----------
function Configure-CARegistryBaseline {
  param([Parameter(Mandatory)][pscustomobject]$Config)

  Write-Log "Stopping CertSvc for baseline config"
  Stop-Service -Name CertSvc -Force -ErrorAction SilentlyContinue

  Write-Log "Enabling CA auditing (AuditFilter=127)"
  & certutil.exe -setreg CA\AuditFilter 127 | Out-Null

  if ($Config.ca.type -like 'Enterprise*') {
    Write-Log "Enabling RoleSeparationEnabled=1 (Enterprise CA)"
    & certutil.exe -setreg CA\RoleSeparationEnabled 1 | Out-Null
  }

  Write-Log "Starting CertSvc after baseline config"
  Start-Service -Name CertSvc
}
#endregion

#region ---------- LDIF parsing + Directory import (OIDs/Templates) ----------
function Unfold-LdifLines {
  param([Parameter(Mandatory)][string[]]$Lines)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $Lines) {
    if ($line.StartsWith(' ') -and $out.Count -gt 0) {
      $out[$out.Count - 1] = $out[$out.Count - 1] + ($line.TrimStart())
    } else {
      $out.Add($line)
    }
  }
  return $out.ToArray()
}

function Read-LdifEntries {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path $Path)) { throw "LDF not found: $Path" }
  $rawLines = Get-Content -Path $Path
  $lines = Unfold-LdifLines -Lines $rawLines

  $entries = @()
  $current = @()
  foreach ($l in $lines) {
    if ([string]::IsNullOrWhiteSpace($l)) {
      if ($current.Count -gt 0) { $entries += ,$current; $current = @() }
      continue
    }
    $current += $l
  }
  if ($current.Count -gt 0) { $entries += ,$current }

  $parsed = @()
  foreach ($e in $entries) {
    $obj = [ordered]@{}
    $multi = @{}
    foreach ($line in $e) {
      if ($line -match '^\s*#') { continue }
      $idx = $line.IndexOf(':')
      if ($idx -lt 1) { continue }

      if ($line.Contains('::')) {
        $idx2 = $line.IndexOf('::')
        $k = $line.Substring(0, $idx2).Trim()
        $b64 = $line.Substring($idx2 + 2).Trim()
        $val = [Convert]::FromBase64String($b64)
      } else {
        $k = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
      }

      if ($k -in $multi.Keys) {
        $multi[$k] += ,$val
      } elseif ($obj.Contains($k)) {
        $multi[$k] = @($obj[$k], $val)
        $obj.Remove($k) | Out-Null
      } else {
        $obj[$k] = $val
      }
    }
    foreach ($mk in $multi.Keys) { $obj[$mk] = $multi[$mk] }
    $parsed += [pscustomobject]$obj
  }
  return $parsed
}

function Get-PkiConfigDn {
  Ensure-Module -Name ActiveDirectory
  return (Get-ADRootDSE).configurationNamingContext
}

function Upsert-EnterpriseOid {
  param(
    [Parameter(Mandatory)][string]$Cn,
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Oid,
    [int]$Flags = 0,
    [Parameter(Mandatory)][string]$OidsContainerDn
  )

  Ensure-Module -Name ActiveDirectory

  $dn = "CN=$Cn,$OidsContainerDn"
  $existing = Get-ADObject -Identity $dn -ErrorAction SilentlyContinue

  $attrs = @{
    displayName = $DisplayName
    'msPKI-OID' = $Oid
    flags       = $Flags
  }

  if (-not $existing) {
    Write-Log "Creating Enterprise OID: $Cn ($Oid)"
    New-ADObject -Name $Cn -Type 'msPKI-Enterprise-Oid' -Path $OidsContainerDn -OtherAttributes $attrs | Out-Null
  } else {
    Write-Log "Updating Enterprise OID: $Cn ($Oid)"
    Set-ADObject -Identity $dn -Replace $attrs | Out-Null
  }
}

function Normalize-TemplateAttributes {
  param([Parameter(Mandatory)][pscustomobject]$Entry)

  $drop = @(
    'dn','changetype','distinguishedName','instanceType','whenCreated','whenChanged',
    'uSNCreated','uSNChanged','objectGUID','objectCategory','dSCorePropagationData','name','objectClass'
  )
  $attrs = @{}
  foreach ($p in $Entry.PSObject.Properties) {
    if ($p.Name -in $drop) { continue }
    if ($p.Name -ieq 'cn') { continue }

    $val = $p.Value
    if ($val -is [string] -and $val -match '^-?\d+$') { $val = [int]$val }
    $attrs[$p.Name] = $val
  }
  return $attrs
}

function Upsert-CertificateTemplate {
  param(
    [Parameter(Mandatory)][pscustomobject]$Entry,
    [Parameter(Mandatory)][string]$TemplatesContainerDn
  )

  Ensure-Module -Name ActiveDirectory

  $cn = $Entry.cn
  if (-not $cn) { throw "Template entry missing 'cn' in LDF." }
  $dn = "CN=$cn,$TemplatesContainerDn"
  $existing = Get-ADObject -Identity $dn -ErrorAction SilentlyContinue
  $attrs = Normalize-TemplateAttributes -Entry $Entry

  if (-not $existing) {
    Write-Log "Creating certificate template: $cn"
    New-ADObject -Name $cn -Type 'pKICertificateTemplate' -Path $TemplatesContainerDn -OtherAttributes $attrs | Out-Null
  } else {
    Write-Log "Updating certificate template: $cn"
    Set-ADObject -Identity $dn -Replace $attrs | Out-Null
  }
}

function Publish-CATemplate {
  param([Parameter(Mandatory)][string]$TemplateName)

  Write-Log "Publishing template to CA issuance list: $TemplateName"
  & certutil.exe -SetCATemplates + $TemplateName | Out-Null
}
#endregion

#region ---------- Main ----------
Assert-Admin

$config = if ($ConfigPath) { Import-YamlConfig -Path $ConfigPath } else { [pscustomobject]@{} }
if (-not $config.ca) { $config | Add-Member -NotePropertyName ca -NotePropertyValue ([pscustomobject]@{}) }

if (-not $CAType) {
  $CAType = if ($config.ca.type) { [string]$config.ca.type } else {
    Prompt-Choice -Question "Select CA Type" -Options @('StandaloneRootCA','StandaloneSubordinateCA','EnterpriseRootCA','EnterpriseSubordinateCA')
  }
}
$config.ca.type = $CAType

if (-not $PSBoundParameters.ContainsKey('CreateDirectoryObjects')) {
  if ($config.directory -and $config.directory.createDirectoryObjects -ne $null) {
    $CreateDirectoryObjects = [bool]$config.directory.createDirectoryObjects
  } else {
    $CreateDirectoryObjects = ((Read-Host "Create/import OIDs and templates after CA setup? (y/n)") -match '^(y|yes)$')
  }
}
if (-not $PSBoundParameters.ContainsKey('PublishTemplates')) {
  if ($config.directory -and $config.directory.publishTemplates -ne $null) {
    $PublishTemplates = [bool]$config.directory.publishTemplates
  } else {
    $PublishTemplates = ((Read-Host "Publish configured templates to this CA for issuance? (y/n)") -match '^(y|yes)$')
  }
}

Ensure-Module -Name ADCSDeployment

Write-CAPolicyInf -Config $config
Ensure-WindowsFeature -Name @('ADCS-Cert-Authority')

$caParams = @{ CAType = $config.ca.type; Force = $true }
if ($config.ca.commonName) { $caParams.CACommonName = [string]$config.ca.commonName }
if ($config.ca.distinguishedNameSuffix) { $caParams.CADistinguishedNameSuffix = [string]$config.ca.distinguishedNameSuffix }
if ($config.ca.cryptoProviderName) { $caParams.CryptoProviderName = [string]$config.ca.cryptoProviderName }
if ($config.ca.keyLength) { $caParams.KeyLength = [int]$config.ca.keyLength }
if ($config.ca.hashAlgorithmName) { $caParams.HashAlgorithmName = [string]$config.ca.hashAlgorithmName }
if ($config.ca.databaseDirectory) { $caParams.DatabaseDirectory = [string]$config.ca.databaseDirectory }
if ($config.ca.logDirectory) { $caParams.LogDirectory = [string]$config.ca.logDirectory }

if ($config.ca.type -in @('StandaloneRootCA','EnterpriseRootCA')) {
  if ($config.ca.validityPeriod -and $config.ca.validityPeriodUnits) {
    $caParams.ValidityPeriod      = [string]$config.ca.validityPeriod
    $caParams.ValidityPeriodUnits = [int]$config.ca.validityPeriodUnits
  }
}

if ($config.ca.type -in @('EnterpriseSubordinateCA','StandaloneSubordinateCA')) {
  if ($config.ca.parentCA) { $caParams.ParentCA = [string]$config.ca.parentCA }
  if ($config.ca.outputCertRequestFile) { $caParams.OutputCertRequestFile = [string]$config.ca.outputCertRequestFile }
  if ($config.ca.certFile) {
    $caParams.CertFile = [string]$config.ca.certFile
    if ($config.ca.certFilePassword) {
      $caParams.CertFilePassword = (ConvertTo-SecureString -String ([string]$config.ca.certFilePassword) -AsPlainText -Force)
    } else {
      $caParams.CertFilePassword = (Read-Host "Enter password for CertFile (PFX/P12)" -AsSecureString)
    }
  }
}

if ($PSCmdlet.ShouldProcess("LocalHost","Install ADCS CA ($($config.ca.type))")) {
  Write-Log "Installing/configuring CA: $($config.ca.type)"
  Install-AdcsCertificationAuthority @caParams
  Write-Log "CA install completed." 'OK'
}

Configure-CARegistryBaseline -Config $config

$dist = if ($config.capolicy) { $config.capolicy.distribution } else { $null }
if ($dist -and $dist.httpBaseUrl) {
  $includeLdap = if ($dist.includeLdap -ne $null) { [bool]$dist.includeLdap } elseif ($config.ca.type -like 'Enterprise*') { $true } else { $false }
  $publishToShare = if ($dist.publishToShare -ne $null) { [bool]$dist.publishToShare } else { $true }

  $shareHost = $null; $shareName = $null; $localPath = $null
  if ($dist.pkiShare) {
    $shareHost = [string]$dist.pkiShare.host
    $shareName = [string]$dist.pkiShare.name
    $localPath = [string]$dist.pkiShare.localPath
  }

  if ($publishToShare -and $shareHost -and $shareName -and $localPath) {
    Ensure-PkiShareAndIis -ShareHost $shareHost -ShareName $shareName -LocalPath $localPath
  } else {
    Write-Log "Publish-to-share disabled or pkiShare incomplete; will not create SMB share/IIS PKI directory." 'INFO'
  }

  Configure-CdpAiaDistribution -HttpBaseUrl ([string]$dist.httpBaseUrl) -ShareHost $shareHost -ShareName $shareName -IncludeLdap $includeLdap -PublishToShare $publishToShare
  Write-Log "CDP/AIA distribution configured." 'OK'
} else {
  Write-Log "No capolicy.distribution.httpBaseUrl provided; skipping CDP/AIA configuration." 'WARN'
}

if ($config.ca.webEnrollment) {
  if (-not $config.ca.commonName) { throw "ca.commonName is required when webEnrollment=true." }
  Install-WebEnrollment -CACommonName ([string]$config.ca.commonName)
  Write-Log "Web Enrollment installed." 'OK'
}

if ($CreateDirectoryObjects) {
  if (-not (Test-DomainJoined)) {
    Write-Log "Host is not domain-joined. Skipping AD OID/template import." 'WARN'
  } else {
    Ensure-Module -Name ActiveDirectory
    $configNC = Get-PkiConfigDn
    $pkiDn = "CN=Public Key Services,CN=Services,$configNC"
    $oidsDn = "CN=OID,$pkiDn"
    $templatesDn = "CN=Certificate Templates,$pkiDn"

    if ($config.directory -and $config.directory.oids -and $config.directory.oids.ldfPath) {
      $oidLdf = [string]$config.directory.oids.ldfPath
      Write-Log "Importing Enterprise OIDs from: $oidLdf"
      $oidEntries = Read-LdifEntries -Path $oidLdf
      foreach ($e in $oidEntries) {
        if (-not $e.cn -or -not $e.'msPKI-OID') { continue }
        $cn = [string]$e.cn
        $disp = if ($e.displayName) { [string]$e.displayName } else { $cn }
        $oid  = [string]$e.'msPKI-OID'
        $flags = if ($e.flags) { [int]$e.flags } else { 0 }
        Upsert-EnterpriseOid -Cn $cn -DisplayName $disp -Oid $oid -Flags $flags -OidsContainerDn $oidsDn
      }
    } else {
      Write-Log "No directory.oids.ldfPath specified; skipping OID LDF import." 'WARN'
    }

    if ($config.directory -and $config.directory.templates -and $config.directory.templates.ldfPath) {
      $tplLdf = [string]$config.directory.templates.ldfPath
      Write-Log "Importing certificate templates from: $tplLdf"
      $tplEntries = Read-LdifEntries -Path $tplLdf
      foreach ($e in $tplEntries) {
        if (-not $e.cn) { continue }
        Upsert-CertificateTemplate -Entry $e -TemplatesContainerDn $templatesDn
      }
    } else {
      Write-Log "No directory.templates.ldfPath specified; skipping template LDF import." 'WARN'
    }
  }
}

if ($PublishTemplates) {
  if ($config.directory -and $config.directory.templates -and $config.directory.templates.issueTemplates) {
    foreach ($t in $config.directory.templates.issueTemplates) {
      Publish-CATemplate -TemplateName ([string]$t)
    }
    Write-Log "Template publishing complete." 'OK'
  } else {
    Write-Log "PublishTemplates requested but directory.templates.issueTemplates not provided." 'WARN'
  }
}

Write-Log "All operations complete." 'OK'
#endregion
