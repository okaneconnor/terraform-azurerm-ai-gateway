# Operations & hardening

Operational guidance: deployment gotchas, preview features, production hardening,
cost, and linting/scanning. For day-one usage see [usage.md](usage.md); for design
rationale see [architecture.md](architecture.md).

## Deployment gotchas (read before filing issues)

- **APIM creation takes 30-45+ min** (VNet injection). The module sets 3h timeouts.
- **Fresh VNet-injected APIM can drop all inbound** (gateway 443 *and* management
  3443) ~25 min after activation while every health signal reports healthy. Fix:
  `az apim apply-network-updates -g <rg> -n <apim>`; recovery takes ~10-15 min. Not
  config drift — plan stays clean.
- **New Log Analytics workspaces take up to ~2h to start ingesting.** Empty tables
  right after deploy are not a failure. The LLM-token table is the SINGULAR
  `ApiManagementGatewayLlmLog`; the gateway table is the plural
  `ApiManagementGatewayLogs`.
- **Concurrent model deployments to one account can 409** transiently — re-apply, or
  use `-parallelism=1`.
- **Semantic-cache "No appropriate cache found"**: the APIM external cache must be
  registered for the gateway's region display name; the module derives this from
  `var.location` automatically.

## A2A agent APIs (manual step)

No stable ARM `apiType` exists for A2A agent import (portal-only as of 2026-06).
Register via APIM → APIs → + Add API → A2A Agent; it auto-syncs to the API Center
catalogue. Track the [APIM roadmap](https://aka.ms/apimroadmap).

## Production hardening

- `apim_sku_name = "Premium_2"` for SLA + zone redundancy; set
  `apim_virtual_network_type = "Internal"` plus Application Gateway + WAF v2 for a
  private front door with public ingress.
- Tighten `allowed_client_cidrs` to your egress ranges.
- Leave `create_demo_clients = false`; onboard real apps via app-role assignment. If
  you used demo clients for acceptance testing, delete them after.
- Remote state with locking (`azurerm` backend), CI with `fmt -check` → `validate` →
  `terraform test` → gated `plan`/`apply`.
- Rotate any client secrets through Key Vault; prefer certificate credentials or
  workload identity federation over secrets where possible.

## Cost

Main standing costs: APIM (Developer ~£40/mo; Premium materially more), Azure Managed
Redis (smallest SKU, 24/7 — disable `semantic_cache` if unused), Content Safety
per-call (every prompt), and per-token model usage. `terraform destroy` your
deployment when not in use.

## Linting & security scanning

```bash
terraform fmt -recursive          # format
terraform validate                # validate (after: terraform init -backend=false)
terraform test                    # plan-mode unit tests (mocked providers, no Azure creds)
terraform-docs .                  # regenerate the Inputs/Outputs tables in the README
trivy config . && checkov -d .    # static analysis (or: pre-commit run -a)
```

Install the tooling with `brew install terraform-docs trivy checkov pre-commit`. A
[`.pre-commit-config.yaml`](../.pre-commit-config.yaml) wires `fmt` → `validate` →
`terraform-docs` → `trivy` → `checkov` so they run on every commit (`pre-commit
install`, or `pre-commit run -a` on demand).

Both scanners run clean. The handful of checkov skips are documented inline as
`#checkov:skip=<ID>:<reason>` next to the resource and are all either false positives
(e.g. `CKV_AZURE_215` flags the APIM backend `protocol = "http"` *type*, though the
backend URL is the private **https** Cognitive endpoint) or deliberate design choices
(`CKV_AZURE_174` — External VNet mode intentionally exposes a JWT+IP-gated public
gateway; use `apim_virtual_network_type = "Internal"` for a private front door).

## Disaster recovery

**This module is your DR mechanism.** Everything the gateway is — the APIM service, VNet
injection, APIs, policies, products, named values, backends, tiers, the Foundry account and
model deployments, Key Vault, and private endpoints — is defined in this Terraform. A region
loss or an accidental delete is recovered by **re-applying the module** (optionally into a new
region). That is the [IaC approach Microsoft recommends](https://learn.microsoft.com/azure/well-architected/service-guides/azure-api-management#reliability)
for API Management DR — the code *is* the backup, so there is nothing separate to keep in sync.

Microsoft's guidance is to layer three things; two of them are code, and this module covers
the largest:

- **IaC (this module).** Re-apply to reconstitute the gateway. Keep the Terraform in source
  control — that history is your restore point.
- **APIOps** for API-layer config changed *outside* Terraform. If teams edit APIs or policies
  directly on the running service, extract them to Git and publish via a pipeline with
  [APIOps](https://learn.microsoft.com/azure/architecture/example-scenario/devops/automated-api-deployments-apiops).
  (APIM's built-in Git config repo was retired in March 2025; APIOps is the supported replacement.)
- **Native `.apimbackup`** is a *supplement* for **runtime data IaC doesn't hold** — developer-
  portal content and APIM subscriptions/users. This gateway is **keyless** (auth is Entra app
  roles, not APIM subscriptions) and programmatic (no developer portal), so there is little such
  state to protect; for most deployments the IaC layer already covers it. If a compliance mandate
  requires point-in-time snapshots, run the native backup **on a schedule from your own automation**
  (Automation runbook, Logic App, or CI pipeline) using the managed-identity operation — never a
  hand-run command:

  ```powershell
  # From scheduled automation. The APIM system-assigned identity needs
  # Storage Blob Data Contributor on the target storage account.
  Backup-AzApiManagement -ResourceGroupName $rg -Name $apim `
    -StorageContext (New-AzStorageContext -StorageAccountName $sa) `
    -SourceContainerName backups -TargetBlobName "apim-$(Get-Date -f yyyyMMdd).apimbackup" `
    -AccessType SystemAssignedManagedIdentity
  ```

  Native backups **expire after 30 days** and restore only into a **same-SKU/region** service, so
  they complement — never replace — the IaC restore path above.
