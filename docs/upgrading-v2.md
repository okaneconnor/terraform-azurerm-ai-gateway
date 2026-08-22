# Upgrading to v2

v2 standardises every resource name on the [Azure CAF convention](naming.md) and
removes the random name suffix. **Renaming an Azure resource is a replace, not an
in-place update**, so read this before running `apply`.

## What changed

| v1 | v2 |
| --- | --- |
| `aigw-apim-x7k2p` (random 5-char suffix) | `apim-aigw-uks` (deterministic) |
| Token order varied per resource | One order: `<type>-<prefix>[-<env>][-<region>][-<instance>]` |
| Type abbreviation in the middle, or absent | CAF type abbreviation first |
| `var.name_suffix` (random when unset) | **Removed.** Use `var.instance` |
| — | New: `var.environment`, `var.instance`, `var.custom_names` |

Three abbreviations were corrected to match the CAF table: Foundry accounts
`fdry` → **`aif`**, private endpoints `pe` → **`pep`**, Managed Redis
`redis` → **`amr`**.

## Choose your path

### Path A — adopt v2 without renaming anything (recommended for live gateways)

Pin the names your deployment already has with `custom_names`. Nothing is renamed, so
nothing is replaced: you get the v2 module with your existing resources intact.

```bash
# Read the names your current deployment uses
terraform state show azurerm_api_management.apim | grep -E '^\s+name'
terraform state show 'azurerm_key_vault.main["this"]' | grep -E '^\s+name'
```

```hcl
module "ai_gateway" {
  source  = "okaneconnor/ai-gateway/azurerm"
  version = "~> 2.0"

  custom_names = {
    resource_group = "aigw-uks-rg"
    apim           = "aigw-apim-x7k2p"
    key_vault      = "aigwkvx7k2p"
    foundry        = "aigw-fdry-x7k2p"
    log_analytics  = "aigw-law-x7k2p"
    app_insights   = "aigw-appi-x7k2p"
    api_center     = "aigw-apic-x7k2p"
    redis          = "aigw-redis-x7k2p"
    vnet           = "aigw-vnet-x7k2p"
  }
}
```

Then **confirm the plan is empty** before applying:

```bash
terraform plan   # expect: No changes.
```

A non-empty plan means a name is still drifting — compare it against
`terraform state list` before proceeding. Resources not covered by `custom_names`
(alerts, budget, private endpoints, NSGs, the action group, per-service Cognitive
accounts) **will** be renamed and replaced under this path. They are cheap,
stateless resources, but check the plan: replacing a private endpoint briefly
interrupts traffic to its target.

### Path B — blue/green onto the new names

Stand a new deployment up beside the old one, cut consumers over, then destroy the
old one. No downtime, but you pay for two gateways during the overlap.

```hcl
# New deployment, new state
module "ai_gateway_v2" {
  source      = "okaneconnor/ai-gateway/azurerm"
  version     = "~> 2.0"
  name_prefix = "aigw"
  environment = "prod"
  instance    = "002"   # distinct from the v1 deployment
}
```

1. Apply the new deployment into a **separate state**.
2. Re-onboard clients (the new gateway has its own Entra app registration and its own
   app-role assignments).
3. Verify with the smoke test: no token → 401, valid token → 200, harmful prompt → 403.
4. Cut consumers over to the new `apim_gateway_url`.
5. Destroy the v1 deployment.

### Path C — accept the replacement

Let v2 rename everything in place. `terraform apply` destroys and recreates the
gateway. **Expect an outage of roughly 45–90 minutes** (APIM alone takes 30–45
minutes to create) and note the blast radius:

- New APIM instance → **new gateway hostname**, every client must be reconfigured
- New Entra app registration → **every client must be re-onboarded** (new app-role
  assignments, new token audience)
- New Key Vault → secrets recreated; purge-protected vaults hold the **old name** for
  the retention period, so the new vault needs a different name
- New Foundry account → model deployments recreated, quota re-consumed
- API Center holds its old name with **no purge API**, so set a different `instance`

Only reasonable for sandbox or pre-production.

## Input migration

```diff
- name_suffix = "prod01"
+ instance    = "01"
+ environment = "prod"
```

`name_suffix` is removed. If you set it purely for determinism, you no longer need
it — v2 is deterministic by default. If you set it to disambiguate two deployments,
use `instance`.

## After upgrading

Re-run your contract checks against the gateway:

```bash
# no token -> 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY"
# valid token -> 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d "$BODY"
```
