# Complete example — every knob, nothing hardcoded

Exercises the full configurable surface of the module. Every tunable value (SKUs,
sizes, capacities, retention, thresholds, toggles, tiers, models) is wired to this
example's **own variables** (see `variables.tf`) with sensible defaults — so you can
override anything from the command line or a `.tfvars` file without editing HCL.

It also demonstrates:

- A **third tier** (`ai-premium`) — proving that adding a tier is one map entry
  (Entra app role + rate/token policy branches render automatically).
- **Demo clients** (`create_demo_clients = true`) — one client per tier, used by the
  `test/` scripts for end-to-end verification.
- **Integration outputs** (`apim_principal_id`, `vnet_id`, `private_dns_zone_ids`, …)
  for peering and wiring the gateway into a wider estate.

## Usage

```bash
terraform init
terraform apply -var subscription_id=<your-subscription-id>

# override anything without touching main.tf, e.g.:
terraform apply \
  -var subscription_id=<sub> \
  -var apim_sku_name=Premium_1 \
  -var redis_high_availability=true \
  -var log_retention_days=90 \
  -var 'allowed_client_cidrs=["203.0.113.0/24"]'
```

## Bring-your-own (landing zone)

To inject into existing infrastructure instead of creating it, add to the `module`
block in `main.tf` (commented hints are already there):

```hcl
existing_resource_group_name        = "platform-ai-rg"
existing_network                    = { vnet_id = "...", apim_subnet_id = "...", pe_subnet_id = "..." }
existing_private_dns_zone_ids        = { cognitive = "...", openai = "...", aiservices = "...", keyvault = "...", redis = "..." }
existing_log_analytics_workspace_id  = "..."
```

## Tests

After apply, see the module README's **Tests** section for the env-var export block
and the `test/*.sh` suite (auth, tiers, cache, residency, smoke).
