param(
    [string]$CAConfig = "cotpa-subca01.cantrelloffice.cloud\Cantrell Cloud Issuing Certificate Authority 02",
    [string]$OutputDir = "outputs",
    [string]$OutputYamlPath = "cantrelloffice.cloud-templates.yaml",
    [switch]$NoTable,
    [switch]$ListCAConfigs,
    [switch]$ExportTemplates,
    [string]$ExportLdifPath = "cantrelloffice.cloud-templates.ldf",
    [switch]$ExportOids,
    [string]$ExportOidsLdifPath = "cantrelloffice.cloud-oids.ldf",
    [switch]$ShowTemplateOids,
    [string]$ExportOidsPath = "cantrelloffice.cloud-oids.yaml",
    [string]$CustomOidDefinitionsPath = "",
    [switch]$ImportTemplates,
    [string]$ImportLdifPath = "cantrelloffice.cloud-templates.ldf",
    [switch]$ImportOids,
    [string]$ImportOidsLdifPath = "cantrelloffice.cloud-oids.ldf",
    [string]$NamePrefix = "",
    [switch]$NoPrefixDisplayName,
    [string]$PublishToCAConfig = ""
)

$ErrorActionPreference = "Stop"

function Resolve-OutputPath {
    param(
        [string]$Directory,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    Join-Path -Path $Directory -ChildPath $Path
}

function Normalize-CAConfig {
    param([string]$Config)

    $Config -replace "\\\\+", "\\"
}

function Get-CAConfigs {
    $certutil = Get-Command certutil -ErrorAction SilentlyContinue
    if (-not $certutil) {
        throw "certutil.exe not found. Install AD CS tools or run on a CA/RSAT host."
    }

    $raw = & certutil -config - -ping 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($raw | Out-String).Trim()
        if (-not $message) {
            $message = "certutil failed with exit code $LASTEXITCODE"
        }
        throw "certutil failed while listing CA configs.`n$message"
    }

    $raw
}

function Get-CATemplates {
    param([string]$Config)

    $Config = Normalize-CAConfig -Config $Config

    $certutil = Get-Command certutil -ErrorAction SilentlyContinue
    if (-not $certutil) {
        throw "certutil.exe not found. Install AD CS tools or run on a CA/RSAT host."
    }

    $raw = & certutil -config $Config -catemplates 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($raw | Out-String).Trim()
        if (-not $message) {
            $message = "certutil failed with exit code $LASTEXITCODE"
        }
        throw "certutil query failed for CA config '$Config'.`n$message"
    }
    if (-not $raw) {
        throw "No output from certutil. Check CA config: $Config"
    }

    $accessDenied = $false
    $templates = @()
    foreach ($line in $raw) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed -match "^CertUtil:") { continue }
        if ($trimmed -match "Access is denied") { $accessDenied = $true; continue }
        if ($trimmed -match "^Current CA certificate templates") { continue }
        if ($trimmed -match "^Templates on this CA") { continue }
        if ($trimmed -match ":") { continue }
        $templates += $trimmed
    }

    if ($templates.Count -gt 0) {
        return ($templates | Sort-Object -Unique)
    }

    if ($accessDenied) {
        Write-Warning "certutil returned Access is denied. Falling back to Active Directory for published templates."
    } else {
        Write-Warning "certutil returned no templates. Falling back to Active Directory for published templates."
    }

    $parts = Split-CAConfig -Config $Config
    return Get-CATemplatesFromAD -CAName $parts.CAName -CAHost $parts.CAHost
}

function Split-CAConfig {
    param([string]$Config)

    $Config = Normalize-CAConfig -Config $Config

    $parts = $Config.Split('\\', 2)
    if ($parts.Count -ne 2) {
        throw "CA config '$Config' is not in 'HOST\\CA-NAME' format."
    }

    return [pscustomobject]@{
        CAHost = $parts[0]
        CAName = $parts[1]
    }
}

function Get-CATemplatesFromAD {
    param(
        [string]$CAName,
        [string]$CAHost
    )

    $configNc = Get-ConfigNamingContext
    $searchBase = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNc"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue

    $templates = $null
    if ($useAdCmdlets) {
        $ca = Get-ADObject -LDAPFilter "(&(objectClass=pKIEnrollmentService)(|(cn=$CAName)(dNSHostName=$CAHost)))" -SearchBase $searchBase -Properties certificateTemplates
        if ($ca) {
            $templates = $ca.certificateTemplates
        }
    } else {
        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = "LDAP://$searchBase"
        $searcher.Filter = "(&(objectClass=pKIEnrollmentService)(|(cn=$CAName)(dNSHostName=$CAHost)))"
        $searcher.PropertiesToLoad.Add("certificateTemplates") | Out-Null
        $found = $searcher.FindOne()
        if ($found) {
            $templates = $found.Properties["certificateTemplates"]
        }
    }

    if (-not $templates) {
        throw "No published templates found in AD for CA '$CAName' on '$CAHost'."
    }

    $templates | Sort-Object -Unique
}

if ($ListCAConfigs) {
    Get-CAConfigs
    return
}

if ($ImportOids) {
    Import-OidLdif -Path $ImportOidsLdifPath
    Write-Host "Imported OIDs from $ImportOidsLdifPath"
    if (-not $ImportTemplates) {
        return
    }
}

if ($ImportTemplates) {
    if (-not $NamePrefix) {
        $NamePrefix = Read-Host "Enter prefix for imported template names (leave blank for none)"
    }

    $configNc = Get-ConfigNamingContext
    Ensure-CustomOidObjects -ConfigNamingContext $configNc -DefinitionsPath $CustomOidDefinitionsPath

    $imported = Import-TemplateLdif -Path $ImportLdifPath -Prefix $NamePrefix -SkipDisplayName:$NoPrefixDisplayName
    Publish-TemplatesToCA -Config $PublishToCAConfig -TemplateNames $imported
    Write-Host "Imported templates from $ImportLdifPath"
    if ($PublishToCAConfig) {
        Write-Host "Published templates to $PublishToCAConfig"
        Validate-TemplatesPublished -Config $PublishToCAConfig -TemplateNames $imported
    }
    return
}

if (-not (Test-Path -Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

$OutputYamlPath = Resolve-OutputPath -Directory $OutputDir -Path $OutputYamlPath
$ExportLdifPath = Resolve-OutputPath -Directory $OutputDir -Path $ExportLdifPath
$ExportOidsLdifPath = Resolve-OutputPath -Directory $OutputDir -Path $ExportOidsLdifPath
$ExportOidsPath = Resolve-OutputPath -Directory $OutputDir -Path $ExportOidsPath

function Get-ConfigNamingContext {
    $root = [ADSI]"LDAP://RootDSE"
    return $root.configurationNamingContext
}

function Get-TemplateDetails {
    param(
        [string[]]$TemplateNames,
        [string]$ConfigNamingContext
    )

    $searchBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNamingContext"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue

    $results = @()
    foreach ($name in $TemplateNames) {
        if ($useAdCmdlets) {
            $obj = Get-ADObject -LDAPFilter "(cn=$name)" -SearchBase $searchBase -Properties "displayName","msPKI-Cert-Template-OID","msPKI-Template-Schema-Version"
        } else {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = "LDAP://$searchBase"
            $searcher.Filter = "(cn=$name)"
            $searcher.PropertiesToLoad.Add("displayName") | Out-Null
            $searcher.PropertiesToLoad.Add("msPKI-Cert-Template-OID") | Out-Null
            $searcher.PropertiesToLoad.Add("msPKI-Template-Schema-Version") | Out-Null
            $found = $searcher.FindOne()
            $obj = $null
            if ($found) {
                $obj = $found.GetDirectoryEntry()
            }
        }

        $displayName = $null
        $oid = $null
        $schemaVersion = $null

        if ($obj) {
            if ($useAdCmdlets) {
                $displayName = $obj.displayName
                $oid = $obj."msPKI-Cert-Template-OID"
                $schemaVersion = $obj."msPKI-Template-Schema-Version"
            } else {
                $displayName = $obj.Properties["displayName"].Value
                $oid = $obj.Properties["msPKI-Cert-Template-OID"].Value
                $schemaVersion = $obj.Properties["msPKI-Template-Schema-Version"].Value
            }
        }

        $results += [pscustomobject]@{
            Name          = $name
            DisplayName   = $displayName
            Oid           = $oid
            SchemaVersion = $schemaVersion
        }
    }

    $results
}

function Write-Yaml {
    param(
        [object[]]$Items,
        [string]$Path
    )

    $lines = @("templates:")
    foreach ($item in $Items) {
        $lines += ('  - name: "{0}"' -f $item.Name)
        $lines += ('    displayName: "{0}"' -f $item.DisplayName)
        $lines += ('    oid: "{0}"' -f $item.Oid)
        $lines += ('    schemaVersion: {0}' -f $item.SchemaVersion)
    }

    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

function Write-TemplateOidsYaml {
    param(
        [object[]]$Items,
        [string]$Path
    )

    $lines = @("templateOids:")
    foreach ($item in $Items) {
        $lines += ('  - template: "{0}"' -f $item.Template)
        if ($item.Oids) {
            $oidList = $item.Oids -split ",\s*" | Where-Object { $_ } | Where-Object { Test-IsCustomOid -Oid $_ }
            foreach ($oid in $oidList) {
                $lines += ('    - "{0}"' -f $oid)
            }
        } else {
            $lines += "    -"
        }
    }

    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

function Escape-LdapFilterValue {
    param([string]$Value)

    $Value -replace "\\", "\\5c" -replace "\*", "\\2a" -replace "\(", "\\28" -replace "\)", "\\29" -replace "\x00", "\\00"
}

function Test-IsCustomOid {
    param([string]$Oid)

    if (-not $Oid) {
        return $false
    }

    # Treat non-Microsoft enterprise OIDs as custom (exclude 1.3.6.1.4.1.311).
    return ($Oid -like "1.3.6.1.4.1.*") -and ($Oid -notlike "1.3.6.1.4.1.311*")
}

function Get-CustomOidDefinitions {
    param([string]$Path)

    if ($Path -and (Test-Path -Path $Path)) {
        $items = Import-Csv -Path $Path
        $defs = @()
        foreach ($item in $items) {
            if (-not $item.Oid) { continue }
            $defs += [pscustomobject]@{
                Name = $item.Name
                DisplayName = $item.DisplayName
                Oid = $item.Oid
            }
        }

        return $defs
    }

    @(
        [pscustomobject]@{ Name = "PIVKey Authentication 9A"; DisplayName = "PIVKey Authentication 9A"; Oid = "1.3.6.1.4.1.44986.2.1.1" },
        [pscustomobject]@{ Name = "PIVKey Card Authentication 9E"; DisplayName = "PIVKey Card Authentication 9E"; Oid = "1.3.6.1.4.1.44986.2.5.0" },
        [pscustomobject]@{ Name = "PIVKey Digital Signature 9C"; DisplayName = "PIVKey Digital Signature 9C"; Oid = "1.3.6.1.4.1.44986.2.1.0" },
        [pscustomobject]@{ Name = "PIVKey Key Management 9D"; DisplayName = "PIVKey Key Management 9D"; Oid = "1.3.6.1.4.1.44986.2.1.2" }
    )
}

function Write-CustomOidLdif {
    param(
        [object[]]$Definitions,
        [string]$ConfigNamingContext,
        [string]$Path
    )

    $lines = @()
    foreach ($def in $Definitions) {
        if (-not $def.Oid) { continue }
        $name = $def.Name
        if (-not $name) { $name = $def.Oid }
        $displayName = $def.DisplayName
        if (-not $displayName) { $displayName = $name }

        $lines += "dn: CN=$name,CN=OID,CN=Public Key Services,CN=Services,$ConfigNamingContext"
        $lines += "changetype: add"
        $lines += "objectClass: top"
        $lines += "objectClass: msPKI-Enterprise-Oid"
        $lines += "cn: $name"
        $lines += "displayName: $displayName"
        $lines += "msPKI-OID: $($def.Oid)"
        $lines += "flags: 0"
        $lines += ""
    }

    if ($lines.Count -gt 0) {
        Set-Content -Path $Path -Value $lines -Encoding UTF8
    }
}

function Export-TemplateLdif {
    param(
        [string[]]$TemplateNames,
        [string]$ConfigNamingContext,
        [string]$Path
    )

    $ldifde = Get-Command ldifde -ErrorAction SilentlyContinue
    if (-not $ldifde) {
        throw "ldifde.exe not found. Install RSAT AD DS tools or run on a domain-joined admin host."
    }

    $escaped = $TemplateNames | ForEach-Object { "(cn=$(Escape-LdapFilterValue -Value $_))" }
    $filter = "(|{0})" -f ($escaped -join "")
    $base = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNamingContext"

    & ldifde -f $Path -d $base -r $filter -p Subtree | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ldifde failed with exit code $LASTEXITCODE"
    }
}

function Get-TemplatePolicyOids {
    param(
        [string[]]$TemplateNames,
        [string]$ConfigNamingContext
    )

    $searchBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNamingContext"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue
    $oids = @()

    foreach ($name in $TemplateNames) {
        if ($useAdCmdlets) {
            $obj = Get-ADObject -LDAPFilter "(cn=$name)" -SearchBase $searchBase -Properties "msPKI-Certificate-Application-Policy","pKIExtendedKeyUsage","msPKI-Certificate-Policy"
        } else {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = "LDAP://$searchBase"
            $searcher.Filter = "(cn=$name)"
            $searcher.PropertiesToLoad.Add("msPKI-Certificate-Application-Policy") | Out-Null
            $searcher.PropertiesToLoad.Add("pKIExtendedKeyUsage") | Out-Null
            $searcher.PropertiesToLoad.Add("msPKI-Certificate-Policy") | Out-Null
            $found = $searcher.FindOne()
            $obj = $null
            if ($found) {
                $obj = $found.GetDirectoryEntry()
            }
        }

        if ($obj) {
            if ($useAdCmdlets) {
                $oids += $obj."msPKI-Certificate-Application-Policy"
                $oids += $obj.pKIExtendedKeyUsage
                $oids += $obj."msPKI-Certificate-Policy"
            } else {
                $oids += $obj.Properties["msPKI-Certificate-Application-Policy"].Value
                $oids += $obj.Properties["pKIExtendedKeyUsage"].Value
                $oids += $obj.Properties["msPKI-Certificate-Policy"].Value
            }
        }
    }

    $oids | Where-Object { $_ } | Sort-Object -Unique
}

function Get-TemplatePolicyOidsPerTemplate {
    param(
        [string[]]$TemplateNames,
        [string]$ConfigNamingContext
    )

    $searchBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNamingContext"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue
    $results = @()

    foreach ($name in $TemplateNames) {
        if ($useAdCmdlets) {
            $obj = Get-ADObject -LDAPFilter "(cn=$name)" -SearchBase $searchBase -Properties "msPKI-Certificate-Application-Policy","pKIExtendedKeyUsage","msPKI-Certificate-Policy"
        } else {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = "LDAP://$searchBase"
            $searcher.Filter = "(cn=$name)"
            $searcher.PropertiesToLoad.Add("msPKI-Certificate-Application-Policy") | Out-Null
            $searcher.PropertiesToLoad.Add("pKIExtendedKeyUsage") | Out-Null
            $searcher.PropertiesToLoad.Add("msPKI-Certificate-Policy") | Out-Null
            $found = $searcher.FindOne()
            $obj = $null
            if ($found) {
                $obj = $found.GetDirectoryEntry()
            }
        }

        $oids = @()
        if ($obj) {
            if ($useAdCmdlets) {
                $oids += $obj."msPKI-Certificate-Application-Policy"
                $oids += $obj.pKIExtendedKeyUsage
                $oids += $obj."msPKI-Certificate-Policy"
            } else {
                $oids += $obj.Properties["msPKI-Certificate-Application-Policy"].Value
                $oids += $obj.Properties["pKIExtendedKeyUsage"].Value
                $oids += $obj.Properties["msPKI-Certificate-Policy"].Value
            }
        }

        $oidList = ($oids | Where-Object { $_ } | Sort-Object -Unique) -join ", "

        $results += [pscustomobject]@{
            Template = $name
            Oids = $oidList
        }
    }

    $results
}

function Get-CustomOidObjects {
    param(
        [string[]]$Oids,
        [string]$ConfigNamingContext
    )

    if (-not $Oids -or $Oids.Count -eq 0) {
        return @()
    }

    $searchBase = "CN=OID,CN=Public Key Services,CN=Services,$ConfigNamingContext"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue

    $filterParts = $Oids | ForEach-Object { "(msPKI-OID=$(Escape-LdapFilterValue -Value $_))" }
    $filter = "(|{0})" -f ($filterParts -join "")

    if ($useAdCmdlets) {
        try {
            return (Get-ADObject -LDAPFilter $filter -SearchBase $searchBase -Properties "msPKI-OID","displayName")
        } catch {
            $useAdCmdlets = $false
        }
    }

    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.SearchRoot = "LDAP://$searchBase"
    $searcher.Filter = $filter
    $searcher.PropertiesToLoad.Add("msPKI-OID") | Out-Null
    $searcher.PropertiesToLoad.Add("displayName") | Out-Null

    $results = @()
    foreach ($result in $searcher.FindAll()) {
        $results += $result.GetDirectoryEntry()
    }

    $results
}

function Export-OidLdif {
    param(
        [string[]]$TemplateNames,
        [string]$ConfigNamingContext,
        [string]$Path
    )

    $ldifde = Get-Command ldifde -ErrorAction SilentlyContinue
    if (-not $ldifde) {
        throw "ldifde.exe not found. Install RSAT AD DS tools or run on a domain-joined admin host."
    }

    $oids = Get-TemplatePolicyOids -TemplateNames $TemplateNames -ConfigNamingContext $ConfigNamingContext
    $customOidValues = $oids | Where-Object { Test-IsCustomOid -Oid $_ } | Sort-Object -Unique
    $customOids = Get-CustomOidObjects -Oids $customOidValues -ConfigNamingContext $ConfigNamingContext

    if (-not $customOids -or $customOids.Count -eq 0) {
        Write-Host "No custom OID objects found in AD for the selected templates. Creating LDIF from known definitions."
        $definitions = Get-CustomOidDefinitions -Path $CustomOidDefinitionsPath
        if (-not $definitions -or $definitions.Count -eq 0) {
            Write-Host "No custom OID definitions found for export."
            return
        }

        Write-CustomOidLdif -Definitions $definitions -ConfigNamingContext $ConfigNamingContext -Path $Path
        return
    }

    $oidValues = @()
    foreach ($obj in $customOids) {
        if ($obj.Properties["msPKI-OID"].Value) {
            $oidValues += $obj.Properties["msPKI-OID"].Value
        } elseif ($obj."msPKI-OID") {
            $oidValues += $obj."msPKI-OID"
        }
    }

    $oidValues = $oidValues | Where-Object { $_ } | Sort-Object -Unique
    $customOidValues = $oidValues | Where-Object { Test-IsCustomOid -Oid $_ }
    if (-not $customOidValues -or $customOidValues.Count -eq 0) {
        Write-Host "No custom OID values found for export."
        return
    }

    $escaped = $customOidValues | ForEach-Object { "(msPKI-OID=$(Escape-LdapFilterValue -Value $_))" }
    $filter = "(|{0})" -f ($escaped -join "")
    $base = "CN=OID,CN=Public Key Services,CN=Services,$ConfigNamingContext"

    & ldifde -f $Path -d $base -r $filter -p Subtree | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ldifde failed with exit code $LASTEXITCODE"
    }
}

function Get-TemplateNamesFromLdif {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        throw "LDIF path not found: $Path"
    }

    $names = @()
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match "^cn:\s*(.+)$") {
            $names += $Matches[1].Trim()
        }
    }

    $names | Sort-Object -Unique
}

function Apply-TemplatePrefix {
    param(
        [string]$SourcePath,
        [string]$Prefix,
        [switch]$SkipDisplayName
    )

    $map = @{}
    $displayMap = @{}

    foreach ($line in Get-Content -Path $SourcePath) {
        if ($line -match "^cn:\s*(.+)$") {
            $oldName = $Matches[1].Trim()
            if (-not $map.ContainsKey($oldName)) {
                $map[$oldName] = "$Prefix$oldName"
            }
        }

        if (-not $SkipDisplayName -and $line -match "^displayName:\s*(.+)$") {
            $oldDisplay = $Matches[1].Trim()
            if (-not $displayMap.ContainsKey($oldDisplay)) {
                $displayMap[$oldDisplay] = "$Prefix$oldDisplay"
            }
        }
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    $out = @()

    foreach ($line in Get-Content -Path $SourcePath) {
        $newLine = $line

        foreach ($old in $map.Keys) {
            $new = $map[$old]
            $newLine = $newLine -replace "^dn: CN=$([regex]::Escape($old)),", "dn: CN=$new,"
            $newLine = $newLine -replace "^cn:\s*$([regex]::Escape($old))$", "cn: $new"
            $newLine = $newLine -replace "^name:\s*$([regex]::Escape($old))$", "name: $new"
        }

        if (-not $SkipDisplayName) {
            foreach ($oldDisplay in $displayMap.Keys) {
                $newDisplay = $displayMap[$oldDisplay]
                $newLine = $newLine -replace "^displayName:\s*$([regex]::Escape($oldDisplay))$", "displayName: $newDisplay"
            }
        }

        $out += $newLine
    }

    Set-Content -Path $tmp -Value $out -Encoding UTF8

    [pscustomobject]@{
        Path = $tmp
        NameMap = $map
    }
}

function Import-TemplateLdif {
    param(
        [string]$Path,
        [string]$Prefix,
        [switch]$SkipDisplayName
    )

    $ldifde = Get-Command ldifde -ErrorAction SilentlyContinue
    if (-not $ldifde) {
        throw "ldifde.exe not found. Install RSAT AD DS tools or run on a domain-joined admin host."
    }

    $importPath = $Path
    $nameMap = @{}

    if ($Prefix) {
        $result = Apply-TemplatePrefix -SourcePath $Path -Prefix $Prefix -SkipDisplayName:$SkipDisplayName
        $importPath = $result.Path
        $nameMap = $result.NameMap
    }

    & ldifde -i -f $importPath -k | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ldifde import failed with exit code $LASTEXITCODE"
    }

    if ($Prefix) {
        Remove-Item -Path $importPath -Force -ErrorAction SilentlyContinue
        return ($nameMap.Values | Sort-Object -Unique)
    }

    return (Get-TemplateNamesFromLdif -Path $Path)
}

function Import-OidLdif {
    param([string]$Path)

    $ldifde = Get-Command ldifde -ErrorAction SilentlyContinue
    if (-not $ldifde) {
        throw "ldifde.exe not found. Install RSAT AD DS tools or run on a domain-joined admin host."
    }

    if (-not (Test-Path -Path $Path)) {
        throw "LDIF path not found: $Path"
    }

    & ldifde -i -f $Path -k | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ldifde import failed with exit code $LASTEXITCODE"
    }
}

function Ensure-CustomOidObjects {
    param(
        [string]$ConfigNamingContext,
        [string]$DefinitionsPath
    )

    $definitions = Get-CustomOidDefinitions -Path $DefinitionsPath
    if (-not $definitions -or $definitions.Count -eq 0) {
        Write-Host "No custom OID definitions available to create."
        return
    }

    $searchBase = "CN=OID,CN=Public Key Services,CN=Services,$ConfigNamingContext"
    $useAdCmdlets = Get-Command Get-ADObject -ErrorAction SilentlyContinue

    foreach ($def in $definitions) {
        if (-not $def.Oid) { continue }

        $exists = $false
        if ($useAdCmdlets) {
            try {
                $found = Get-ADObject -LDAPFilter "(msPKI-OID=$($def.Oid))" -SearchBase $searchBase -ErrorAction Stop
                if ($found) { $exists = $true }
            } catch {
                $exists = $false
            }
        } else {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = "LDAP://$searchBase"
            $searcher.Filter = "(msPKI-OID=$($def.Oid))"
            $searcher.PropertiesToLoad.Add("msPKI-OID") | Out-Null
            $found = $searcher.FindOne()
            if ($found) { $exists = $true }
        }

        if ($exists) { continue }

        $name = $def.Name
        if (-not $name) { $name = $def.Oid }
        $displayName = $def.DisplayName
        if (-not $displayName) { $displayName = $name }

        $dn = "CN=$name,$searchBase"
        $entry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dn")
        $entry.Properties["objectClass"].Add("top") | Out-Null
        $entry.Properties["objectClass"].Add("msPKI-Enterprise-Oid") | Out-Null
        $entry.Properties["cn"].Value = $name
        $entry.Properties["displayName"].Value = $displayName
        $entry.Properties["msPKI-OID"].Value = $def.Oid
        $entry.Properties["flags"].Value = 0
        $entry.CommitChanges()
    }
}

function Publish-TemplatesToCA {
    param(
        [string]$Config,
        [string[]]$TemplateNames
    )

    if (-not $Config) {
        return
    }

    $certutil = Get-Command certutil -ErrorAction SilentlyContinue
    if (-not $certutil) {
        throw "certutil.exe not found. Install AD CS tools or run on a CA/RSAT host."
    }

    foreach ($name in $TemplateNames) {
        & certutil -config $Config -setcatemplates +$name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "certutil failed to publish template '$name' to CA '$Config'"
        }
    }
}

function Validate-TemplatesPublished {
    param(
        [string]$Config,
        [string[]]$TemplateNames
    )

    if (-not $Config -or -not $TemplateNames -or $TemplateNames.Count -eq 0) {
        return
    }

    $published = Get-CATemplates -Config $Config
    $missing = $TemplateNames | Where-Object { $published -notcontains $_ }

    if ($missing.Count -gt 0) {
        $missingList = $missing -join ", "
        throw "Publish validation failed. Missing templates on CA '$Config': $missingList"
    }

    Write-Host "Validated templates published to $Config"
}

$templates = Get-CATemplates -Config $CAConfig
$configNc = Get-ConfigNamingContext
$details = Get-TemplateDetails -TemplateNames $templates -ConfigNamingContext $configNc

Write-Yaml -Items $details -Path $OutputYamlPath

if ($ShowTemplateOids) {
    Get-TemplatePolicyOidsPerTemplate -TemplateNames $templates -ConfigNamingContext $configNc | Format-Table -AutoSize
}

if ($ExportTemplates) {
    Export-TemplateLdif -TemplateNames $templates -ConfigNamingContext $configNc -Path $ExportLdifPath
    Write-Host "Exported LDIF to $ExportLdifPath"

    if (-not $ExportOids) {
        $oidItems = Get-TemplatePolicyOidsPerTemplate -TemplateNames $templates -ConfigNamingContext $configNc
        Write-TemplateOidsYaml -Items $oidItems -Path $ExportOidsPath
        Write-Host "Exported template OIDs to $ExportOidsPath"

        Export-OidLdif -TemplateNames $templates -ConfigNamingContext $configNc -Path $ExportOidsLdifPath
        if (Test-Path -Path $ExportOidsLdifPath) {
            Write-Host "Exported OIDs LDIF to $ExportOidsLdifPath"
        }
    }
}

if ($ExportOids) {
    $oidItems = Get-TemplatePolicyOidsPerTemplate -TemplateNames $templates -ConfigNamingContext $configNc
    Write-TemplateOidsYaml -Items $oidItems -Path $ExportOidsPath
    Write-Host "Exported template OIDs to $ExportOidsPath"

    Export-OidLdif -TemplateNames $templates -ConfigNamingContext $configNc -Path $ExportOidsLdifPath
    if (Test-Path -Path $ExportOidsLdifPath) {
        Write-Host "Exported OIDs LDIF to $ExportOidsLdifPath"
    }
}

if (-not $NoTable) {
    $details | Sort-Object Name | Format-Table -AutoSize
}

Write-Host "Wrote YAML to $OutputYamlPath"
