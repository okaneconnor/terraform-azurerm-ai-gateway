# Upgrading to v2

v2 standardises every resource name on the [Azure CAF convention](naming.md) and
removes the random name suffix. **Renaming an Azure resource is a replace, not an
in-place update**, so read this before running `apply`.

## What changed

v2 carries **two** breaking changes. Naming is the visible one; admission is the
one that will stop your callers working if you miss it.

### 1. Naming (every resource)

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

### 2. Admission is one app role; tiers are limit presets

v1 gave every tier its own Entra app role, and a caller's tier came from the role
it held. v2 defines **one** role — `var.admission_app_role`, default
`AI.Gateway.Standard` — which answers only "may this identity reach the gateway".
Limits now come from config, not from the token.

```diff
 tiers = {
   standard = {
-    app_role          = "AI.Gateway.Standard"
-    display_name      = "Standard"
     tokens_per_minute = 20000
     rate_limit_calls  = 30
   }
 }
+default_tier = "standard"
```

`app_role` and `display_name` are removed from `var.tiers`. `var.default_tier`
selects which preset applies; it may be omitted only when `var.tiers` has exactly
one entry — the module never guesses between several.

**This breaks existing callers until you re-grant them.** Their tokens carry a
per-tier role that no longer exists on the gateway app, so they will get
`401 invalid_token`. Before upgrading, or immediately after:

```bash
# for every existing caller
az rest --method POST \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$GATEWAY_SP_OBJECT_ID/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$CALLER_SP_OBJECT_ID\",\"resourceId\":\"$GATEWAY_SP_OBJECT_ID\",\"appRoleId\":\"$ADMISSION_ROLE_ID\"}"
```

`$GATEWAY_SP_OBJECT_ID` and `$ADMISSION_ROLE_ID` are the `gateway_app_object_id`
and `gateway_app_role_id` outputs. If you run several tiers today, note that every
admitted caller now gets `default_tier` until you differentiate them — see the
optional seam below.

Bringing your own gateway app? It must define a role whose value matches
`admission_app_role`, or the plan fails with a named error.

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

## Optional: per-team config via the registry

v2 adds [`modules/onboarding`](../modules/onboarding/README.md) — a reviewed YAML
registry, in its own Terraform state, that can also become the authority on each
team's limits, model allowlist and content-safety thresholds.

It is **off unless you set `apim_id`**. Leave it unset and every admitted caller
gets `default_tier`, exactly as described above.

Turning it on is **fail closed**: once active, a caller holding the admission role
but absent from the registry is refused with `403 not_onboarded`. Register every
existing caller *before* you enable it. Policy also reaches the gateway
eventually-consistently, so a newly onboarded caller may briefly still see
`403 not_onboarded` for a few tens of seconds after the apply returns.

Two new error codes come with it: `model_not_permitted` and `not_onboarded`.
Branch on `error.code` as usual.

## After upgrading

Re-run your contract checks against the gateway:

```bash
# no token -> 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$CHAT" -H 'Content-Type: application/json' -d "$BODY"
# valid token -> 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$CHAT" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d "$BODY"
```
