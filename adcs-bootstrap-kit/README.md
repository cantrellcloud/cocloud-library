# ADCS Bootstrap Kit (Cantrell Cloud ES Lab)

This kit installs and configures AD CS for:
- Standalone Offline Root CA (dev.local)
- Enterprise Subordinate CA (dev.local)
- Enterprise Root CA (hypermute.cloud)
- Enterprise Root CA (jdeop.op)

It also optionally:
- Imports Enterprise OIDs (msPKI-Enterprise-Oid) from an LDF
- Imports certificate templates from an LDF
- Publishes selected templates to the CA issuance list
- Installs Web Enrollment
- Configures CRL/AIA distribution:
  - HTTP retrieval: `http://pki.<domain>/pki/...`
  - Optional SMB publish: `file://\\<host>\pki\...` (CA writes to the PKI folder share)
  - Optional LDAP endpoints for Enterprise CAs

## Folder Layout
- `scripts/Invoke-ADCSBootstrap.ps1`  -> main installer
- `configs/*.yaml`                    -> example YAML configs
- `inputs/*.ldf`                      -> your LDF files (templates + OIDs)

## Prereqs
- Run elevated (Administrator).
- Enterprise CA installs:
  - Domain-joined server
  - Sufficient privileges (commonly Enterprise Admin)
- DNS:
  - `pki.dev.local` -> `losubca001`
  - `pki.hypermute.cloud` -> `hmrootca001`
  - `pki.jdeop.op` -> `oprootca001`
- YAML parsing:
  - PowerShell 7+ preferred (ConvertFrom-Yaml).
  - If using Windows PowerShell 5.1, vendor/install the `powershell-yaml` module offline.

## Run Examples

From the kit root directory:

### dev.local offline root (StandaloneRootCA)
```powershell
.\scripts\Invoke-ADCSBootstrap.ps1 -ConfigPath .\configs\dev-offline-root.yaml -Force
```

### dev.local subordinate (EnterpriseSubordinateCA)
```powershell
.\scripts\Invoke-ADCSBootstrap.ps1 -ConfigPath .\configs\dev-subca.yaml -Force
```

### hypermute.cloud enterprise root
```powershell
.\scripts\Invoke-ADCSBootstrap.ps1 -ConfigPath .\configs\hypermute-enterprise-root.yaml -Force
```

### jdeop.op enterprise root
```powershell
.\scripts\Invoke-ADCSBootstrap.ps1 -ConfigPath .\configs\jdeop-enterprise-root.yaml -Force
```

## Offline Root Note (dev.local)
`dev-offline-root.yaml` sets `publishToShare: false` to avoid failure if the offline root cannot reach SMB.
After generating the Root CRL/CRT, manually copy them to the distribution folder on `\\losubca001\pki`
so clients can retrieve via HTTP.

## Safety Note
Only publish the templates you actually need. Over-publishing increases template-abuse risk.
