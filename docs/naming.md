# Resource naming

Every resource this module creates is named from one convention, built in exactly one
place (`locals.tf`). Names are **deterministic** — the module generates no random
component — so you can predict every name before you apply and pre-create policy,
RBAC, DNS records or firewall rules against it.

## The convention

```
<type>-<name_prefix>[-<environment>][-<region>][-<instance>]
```

Following the [Azure CAF naming convention][caf-naming], the **resource type
abbreviation comes first**, and optional tokens drop out cleanly when unset.

| Token | Source | Required | Example |
| --- | --- | --- | --- |
| `type` | [CAF abbreviation][caf-abbrev] for the resource | yes | `apim`, `kv`, `aif` |
| `name_prefix` | `var.name_prefix` — your workload/application name | yes | `aigw` |
| `environment` | `var.environment` | no | `dev`, `prod` |
| `region` | derived from `var.location` | yes | `uks`, `neu`, `eus2` |
| `instance` | `var.instance` | no | `002` |

```hcl
# Minimal — environment and instance unset
name_prefix = "aigw"
location    = "uksouth"
# → rg-aigw-uks, apim-aigw-uks, kv-aigw-uks, aif-aigw-uks

# Full
name_prefix = "contoso"
environment = "prod"
instance    = "002"
# → rg-contoso-prod-uks-002, apim-contoso-prod-uks-002, kv-contoso-prod-uks-002
```

## Names a default deployment produces

With `name_prefix = "aigw"`, `location = "uksouth"`, no environment or instance:

| Resource | CAF type | Name |
| --- | --- | --- |
| Resource group | `rg` | `rg-aigw-uks` |
| API Management | `apim` | `apim-aigw-uks` |
| Foundry account (`AIServices`) | `aif` | `aif-aigw-uks` |
| Key Vault | `kv` | `kv-aigw-uks` |
| Log Analytics workspace | `log` | `log-aigw-uks` |
| Application Insights | `appi` | `appi-aigw-uks` |
| Virtual network | `vnet` | `vnet-aigw-uks` |
| NSG (APIM subnet) | `nsg` | `nsg-apim-aigw-uks` |
| Public IP (zonal External APIM) | `pip` | `pip-apim-aigw-uks` |
| Private endpoint | `pep` | `pep-<target>-aigw-uks` |
| Managed Redis | `amr` | `amr-aigw-uks` |
| API Center | `apic` | `apic-aigw-uks` |
| Action group | `ag` | `ag-aigw-uks` |
| Metric / log alerts | `alert` | `alert-apim-capacity-aigw-uks` |
| Consumption budget | `budget` | `budget-aigw-uks` |
| Content Safety account | `cs` | `cs-aigw-uks` |
| Speech account | `spch` | `spch-aigw-uks` |
| Language account | `lang` | `lang-aigw-uks` |
| Document Intelligence account | `di` | `di-aigw-uks` |
| Backend-pool member account | `aif` | `aif-<member>-aigw-uks` |

`apic` and `alert` are not in the CAF table (Azure publishes no abbreviation for
either); the rest are taken from it directly. The `ai_services` accounts take their
type from each entry's `short_name`, which defaults to the CAF abbreviation for that
Cognitive Services kind.

## Scoped child resources are named short

Resources that are unique **within a parent** don't repeat the base — it would be
noise, and the parent already carries the identity:

| Resource | Scope | Name |
| --- | --- | --- |
| Subnets | virtual network | `snet-apim`, `snet-private-endpoints` |
| NSG rules | network security group | `in-client-443`, `out-kv-443` |
| Private-endpoint connections | private endpoint | `psc-<target>` |
| Private DNS zone links | DNS zone | `link-<key>` |
| Diagnostic settings | target resource | `diag-to-law` |
| APIM APIs / backends / fragments | APIM instance | `foundry-openai`, `semantic-cache` |

## You own uniqueness

Several names here are **globally unique across all of Azure**, because they become
public DNS names or service endpoints:

- API Management (`<name>.azure-api.net`)
- Key Vault
- The Foundry account custom subdomain
- Managed Redis
- API Center
- The public-IP DNS label

Since the module generates nothing random, **two deployments that use the same inputs
will collide** on these. That is deliberate, and matches how CAF and Azure Verified
Modules treat naming: the module composes names, the caller owns uniqueness.

Three ways to stay unique:

1. **Use a `name_prefix` distinctive to your organisation** — `contoso-ai`, not `aigw`.
   This is the normal answer.
2. **Set `var.instance`** to run a second deployment beside the first
   (`apim-aigw-uks` and `apim-aigw-uks-002`).
3. **Set `var.custom_names`** to pin a specific name per resource.

If a name is already taken, Azure rejects it at **apply** with a "name is not
available" error naming the resource.

> **Deleted names can stay reserved.** APIM soft-deletes and holds its name until
> purged (`az apim deletedservice purge --service-name <name> --location <region>`).
> API Center holds its name after deletion and exposes **no purge API** — the name
> frees on Azure's own schedule. If you delete and immediately redeploy, expect to
> change `instance` (or `custom_names.api_center`).

## Length caps

Composed names are checked against their Azure limit at plan time by the
`name_lengths` check, which reports the offending name, its length, the cap, and the
input to change. Nothing is silently truncated: a clipped name can collide with
another deployment's clipped name, which then surfaces as a confusing "already
exists" at apply instead of a clear message up front.

| Resource | Cap |
| --- | --- |
| Key Vault | 24 |
| Managed Redis | 60 |
| API Management | 50 |
| Foundry / Cognitive account | 64 |
| API Center, resource group | 90 |

Key Vault's 24 characters is the binding constraint. With the maximum-length inputs
(`name_prefix` 15 + `environment` 10 + `instance` 4) the composed vault name is 38
characters, so long prefixes need `custom_names.key_vault`.

When the vault is enabled the azurerm provider rejects an over-long name before this
check runs, with a less specific message (`"name" may only contain alphanumeric
characters and dashes and must be between 3-24 chars`). Either way the plan fails —
the check exists so the failure names the knob to turn.

## Overriding names

`var.custom_names` overrides any generated name, for landing zones that mandate their
own convention:

```hcl
custom_names = {
  resource_group = "rg-shared-ai-prod"
  apim           = "apim-platform-shared"
  key_vault      = "kv-platform-ai"
}
```

Keys left unset keep the module's convention. This is also the **upgrade path from
v1** — pin the names an existing deployment already has and it adopts v2 without
renaming, and therefore without replacing, anything. See
[upgrading-v2.md](upgrading-v2.md).

[caf-naming]: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming
[caf-abbrev]: https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations
