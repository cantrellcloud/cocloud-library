# Does Azure / Entra support `.local`

* **Microsoft Entra custom domain verification**: you can’t verify a `.local` name in Entra, because custom domains must be real DNS domains. That means `dev.local` cannot become a verified Entra tenant domain.
* **Hybrid identity sign-in naming with Entra ID / Microsoft 365**: Microsoft’s guidance is to add a **routable UPN suffix** like `dev.jde.cybercom.ic.gov` and move users to that before or during sync. Otherwise, non-routable UPNs can end up mapped to `.onmicrosoft.com`. If this works, a new domain would not have to be created. https://learn.microsoft.com/en-us/microsoft-365/enterprise/prepare-a-non-routable-domain-for-directory-synchronization.
* **UPN Migration**: User login UPN has to be changed in AD to the new UPN suffix to sync with Entra ID. This may be done all at once or best practice is to use a small pilot group of users.
* **Azure Private DNS**: Azure Private DNS does allow private zones like `dev.local`, but Microsoft explicitly says **don’t use `.local` as a best practice** because not all operating systems support it cleanly. So this is supported-but-bad-idea territory, not a hard block.
* `dev.local` and Azure can coexist for DNS forwarding and resolution.
* Ensure DNS forwarding is configured for the new UPN suffix.

**Executive recommendation**

* **Keep** `.local` only as the legacy internal AD DNS namespace and migrate to a new internal AD UPN suffix and only create the new dev domain as a fallback.
* Use a routable internal namespace strategy like an example below;

  * `dev.jde.cybercom.ic.gov` or
  * `jde.cybercom.ic.gov`
