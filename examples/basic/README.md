# Basic example — minimal AI gateway

The smallest possible deployment: pass a subscription and publisher details, take
every other default. You still get the **full** private, keyless, multi-service
gateway — APIM (VNet-injected), Foundry + gpt-4.1-mini + embeddings, the four AI
services behind private endpoints, semantic cache, content safety, two tiers, the
residency policy, API Center, Key Vault, and full observability. Defaults are the
infrastructure; this example just shows the minimal call.

## Usage

```bash
terraform init
terraform apply -var subscription_id=<your-subscription-id>
```

APIM VNet provisioning takes ~30–45 minutes on first apply.

## What to set

| Variable | Default | Notes |
|---|---|---|
| `subscription_id` | — (required) | Target subscription |
| `location` | `uksouth` | Pick a region offering your models as in-region Standard SKUs |
| `publisher_name` / `publisher_email` | example values | Shown in the APIM developer portal |

For tuning any SKU/size/toggle or bringing your own network/workspace, see
[`../complete`](../complete) and the module README.
