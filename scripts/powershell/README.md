# PowerShell Scripts

## Get-DomainCertificateTemplates.ps1

Lists certificate templates published on an AD CS enterprise CA, exports template metadata to YAML, and can export/import template objects via LDIF.

### Requirements

- Domain-joined host with access to AD.
- `certutil.exe` (AD CS tools) to query CA and publish templates.
- `ldifde.exe` (RSAT AD DS tools) for export/import.
- Permissions:
  - Read access to the CA configuration.
  - Read access to Certificate Templates in AD.
  - CA admin rights to publish templates.

### Parameters

- `-CAConfig` : CA config string in `HOST\CA-NAME` format.
- `-OutputDir` : Output directory for generated files (default: `outputs`).
- `-OutputYamlPath` : YAML output path (relative to `-OutputDir` unless absolute).
- `-NoTable` : Skip table output.
- `-ListCAConfigs` : List available CA configs.
- `-ExportTemplates` : Export template objects to LDIF.
- `-ExportLdifPath` : LDIF output path (relative to `-OutputDir` unless absolute).
- `-ExportOids` : Export custom OID objects referenced by the templates (enterprise OIDs excluding Microsoft 1.3.6.1.4.1.311).
- `-ExportOidsLdifPath` : OID LDIF output path (relative to `-OutputDir` unless absolute).
- `-ShowTemplateOids` : Show OIDs referenced by each template.
- `-ExportOidsPath` : YAML output path for OIDs referenced by each template (relative to `-OutputDir` unless absolute).
- `-CustomOidDefinitionsPath` : Optional CSV for custom OID definitions (columns: `Name`, `DisplayName`, `Oid`).
- `-ImportTemplates` : Import template objects from LDIF.
- `-ImportLdifPath` : LDIF input path.
- `-ImportOids` : Import custom OID objects from LDIF.
- `-ImportOidsLdifPath` : OID LDIF input path.
- `-NamePrefix` : Prefix to apply to imported template names.
- `-NoPrefixDisplayName` : Do not prefix display names.
- `-PublishToCAConfig` : Publish imported templates to a target CA.

### Examples

List available CA configs:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ListCAConfigs
```

Export template metadata to YAML:

```powershell
.\Get-DomainCertificateTemplates.ps1
```

Write all outputs to a specific folder:

```powershell
.\Get-DomainCertificateTemplates.ps1 -OutputDir ".\outputs"
```

Export published templates to LDIF (auto-exports custom OIDs to `cantrelloffice.cloud-oids.ldf` unless `-ExportOids` is specified):

```powershell
.\Get-DomainCertificateTemplates.ps1 -ExportTemplates -ExportLdifPath ".\cantrelloffice.cloud-templates.ldf"
```

Export the OIDs referenced by each template (YAML) and attempt LDIF export of custom OID objects:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ExportOids -ExportOidsPath ".\cantrelloffice.cloud-oids.yaml" -ExportOidsLdifPath ".\cantrelloffice.cloud-oids.ldf"
```

Use a custom OID definition CSV when AD does not have OID objects:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ExportOids -CustomOidDefinitionsPath ".\custom-oids.csv"
```

Show OIDs referenced by each template:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ShowTemplateOids
```

Import templates into another domain with a prefix:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ImportTemplates -ImportLdifPath ".\cantrelloffice.cloud-templates.ldf" -NamePrefix "COCloud-"
```

Import templates and prompt for a prefix:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ImportTemplates -ImportLdifPath ".\cantrelloffice.cloud-templates.ldf"
```

Import templates and publish to a target CA:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ImportTemplates -ImportLdifPath ".\cantrelloffice.cloud-templates.ldf" -NamePrefix "COCloud-" -PublishToCAConfig "targetca.contoso.com\Contoso Issuing CA"
```

Import, prompt for a prefix, and publish to a target CA in one step:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ImportTemplates -ImportLdifPath ".\cantrelloffice.cloud-templates.ldf" -PublishToCAConfig "targetca.contoso.com\Contoso Issuing CA"
```

Import custom OIDs first, then import templates:

```powershell
.\Get-DomainCertificateTemplates.ps1 -ImportOids -ImportOidsLdifPath ".\cantrelloffice.cloud-oids.ldf" -ImportTemplates -ImportLdifPath ".\cantrelloffice.cloud-templates.ldf" -NamePrefix "COCloud-"
```

### Notes

- If the CA denies access to `certutil -catemplates`, the script falls back to AD to discover published templates.
- Prefixing changes the template `cn` and `name` attributes. It can also update `displayName` unless `-NoPrefixDisplayName` is used.
- Templates do not contain private keys. New keys are generated when certificates are issued on the target CA.
- OID export/import only includes OID objects registered in AD that are referenced by the selected templates.
- When AD OID objects are missing, the script generates an LDIF from built-in custom OID definitions or the CSV provided via `-CustomOidDefinitionsPath`.
- During template import, the script ensures the custom OID objects exist in the target domain and prompts for a prefix if `-NamePrefix` is not provided.
