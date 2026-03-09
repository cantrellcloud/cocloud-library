$script = "d:\repositories\cocloud\cocloud-library\scripts\powershell\Transfer-DomainCertificateTemplates.ps1"

& $script `
  -ImportOids `
  -ImportOidsLdifPath "outputs\cantrelloffice.cloud-oids.ldf"

& $script `
  -ImportTemplates `
  -ImportLdifPath "outputs\cantrelloffice.cloud-templates.ldf" `
  -NamePrefix "hypermute-" `
  -PublishToCAConfig "hypermuteca.hypermute.cloud\hypermute-HYPERMUTE-CA"