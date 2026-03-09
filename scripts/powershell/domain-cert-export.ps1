$script = "d:\repositories\cocloud\cocloud-library\scripts\powershell\Transfer-DomainCertificateTemplates.ps1"

& $script `
  -CAConfig "cotpa-subca01.cantrelloffice.cloud\Cantrell Cloud Issuing Certificate Authority 02" `
  -OutputDir "outputs" `
  -ExportTemplates `
  -ExportOids