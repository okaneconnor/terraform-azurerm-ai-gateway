# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Multi-member backend pool** (`var.backend_pool`, default single-member) — priority +
  weight load balancing across multiple Foundry endpoints with per-member circuit breakers,
  for the MS-recommended PTU-priority + PAYG-spillover pattern. Members are module-created
  (a private AIServices account + deployments) or bring-your-own (`endpoint_url`). The APIM
  managed identity is granted `Cognitive Services OpenAI User` on each module-created
  member, and on BYO members that supply `managed_identity_scope_id`. (#15)
- **Backend diagnostic settings** (`enable_backend_diagnostics`, default on) — route
  Foundry / Cognitive Services / Key Vault / Managed Redis service logs + metrics to Log
  Analytics, so the model layer has a service-side trace, not just APIM's view (#9).
- **Opt-in Azure Monitor alerting** (`var.alerts`, default off) — an action group (or
  bring-your-own) plus metric alerts (APIM capacity, gateway 5xx, model TPM) and log-query
  alerts (sustained 429 throttling, backend connection failures) (#10).
- **Opt-in resource-group consumption budget** (`var.budget`, default off) with actual +
  forecasted cost-alert notifications, wired to the alerts action group or emails (#11).

### Changed

- **Disaster recovery is documented as IaC-first** (#21): the module *is* the DR mechanism
  — re-applying restores the gateway — supplemented by APIOps for API-layer config that
  changes outside Terraform. Native APIM `.apimbackup` is described as a scheduled-automation
  supplement (for runtime data this keyless gateway largely lacks), not shipped as a
  provision-plus-manual-command half-feature.

### Fixed

- **API Center**: the `azapi` body omitted `sku`, so it created successfully but returned
  400 `A valid Sku is required` on every subsequent apply. Added `sku = { name = "Free" }`
  and `schema_validation_enabled = false`.
- **Redis diagnostic setting**: used `category_group = "allLogs"`, which Azure rejects for
  Managed Redis (redisEnterprise exposes no diagnostic log categories) — every cache +
  backend-diagnostics deployment 400'd. Now metrics-only.
- **`backend_failures` alert KQL**: matched `LastErrorReason has "Backend"`, which never
  matches — APIM records backend-health failures as `PoolIsInactive` (breaker open),
  `BackendConnectionFailure`, etc. The alert would have stayed silent on real failures;
  KQL corrected to those reasons. (Both caught by live behavioral testing, not plan checks.)
- **`docs/usage.md` smoke-test examples used `max_tokens`**, which the GPT-5-family
  models these examples target reject with a 400 (`Unsupported parameter … use
  'max_completion_tokens'`). The examples now use `max_completion_tokens`, matching the
  gotcha already documented in `onboarding.md` and the `examples/complete` walkthrough.

## [1.0.0] — 2026-07-06

First published, Semantic-Versioned release.

### Breaking

- **`model_deployments` is now REQUIRED** (no default). The module intentionally
  ships no default model because Azure deprecates model versions over time —
  callers must pin the model + version they hold quota for. Existing configs that
  relied on the removed default must set `model_deployments` explicitly.

### Added

- `content_safety.enforce_on_completions` — screen model **outputs** (completions)
  with content safety / Prompt Shield, not just inbound prompts.
- **Per-tier token quota**: `tiers[*].token_quota` with a `token_quota_period`, for
  daily/monthly spend caps per tier.
- **APIM TLS floor** (`security` block) that disables SSL3 / TLS1.0 / TLS1.1 and the
  3DES cipher on the gateway.
- Cross-validation that every `model_deployments[*]` SKU falls within the enabled
  `deployment_sku_policy` allowlist — fails at **plan** time, not apply.
- **Bring-your-own composability** for landing-zone adoption — all optional:
  `existing_resource_group_name`, `existing_network` (VNet + APIM/PE subnets),
  `existing_private_dns_zone_ids` (hub-managed DNS),
  `existing_log_analytics_workspace_id`, and `existing_application_insights`.
  When set, the module skips creating that piece and wires to yours.
- `apim_virtual_network_type` — choose `External` (default) or `Internal` VNet
  injection (front Internal with Application Gateway / WAF).
- `apim_zones` — spread Premium APIM units across availability zones for zone
  redundancy. Validated at plan time: Premium SKU only, and zone count must not
  exceed the unit count (the N in `Premium_N`). In External VNet mode the module
  auto-creates a zone-redundant Standard public IP (required by Azure for zonal
  External APIM).
- `name_suffix` — override the random resource-name suffix for deterministic names.
- Tunable knobs that were previously hardcoded: `foundry_account_sku`,
  `log_analytics_sku`, `apim_diagnostic` (sampling/verbosity), `key_vault` object
  (sku / soft-delete retention / purge protection), `semantic_cache.high_availability`,
  and `model_deployments[*].model_format`.
- Integration **outputs**: `apim_id`, `apim_principal_id`, `resource_group_id`,
  `vnet_id`, `apim_subnet_id`, `pe_subnet_id`, `private_dns_zone_ids`,
  `foundry_id`, `application_insights_id`, `application_insights_connection_string`
  (sensitive), `log_analytics_workspace_resource_id`, `log_analytics_workspace_guid`,
  `key_vault_id`, `key_vault_uri`, `api_center_id`.
- Input validation: `tiers[*].app_role` charset (Entra app-role / XML-safe),
  `apim_virtual_network_type` enum, `apim_diagnostic` ranges, `name_suffix` charset.
- terraform-docs config (`.terraform-docs.yml`) and generated Inputs/Outputs in the
  README; this changelog.
- `examples/complete` — a runnable, minimal-but-full consumer configuration that
  deploys the whole gateway, with a smoke-test walkthrough.
- Static analysis wired into the repo: `tfsec` + `checkov` (both run clean) via
  a `.checkov.yaml` config and a `.pre-commit-config.yaml`
  (`fmt` → `validate` → `terraform-docs` → `tfsec` → `checkov`). Checkov false
  positives / by-design items are suppressed inline with documented
  `#checkov:skip=<ID>:<reason>` comments.
- Expanded `terraform test` coverage (20 runs) for every BYO path, Internal mode,
  `name_suffix`, Key Vault knobs, and the new validations.

### Changed

- **Semantic caching now defaults to OFF** (opt-in via `semantic_cache.enabled`).
  It requires Azure Managed Redis (RediSearch), whose SKU capacity varies by
  subscription and region — the cheap `Balanced_B0` default can fail to provision
  (`OperationFailed`). `redis_sku_name` is override-able (e.g. `MemoryOptimized_M10`)
  and the variable docs now call this out; the safe default stays disabled.
- `enable_key_vault` (bool) replaced by the `key_vault` object (`enabled` + tuning).
- Output `log_analytics_workspace_id` split into `log_analytics_workspace_resource_id`
  (ARM id) and `log_analytics_workspace_guid` (customer GUID for KQL).
- Enabled APIM custom metrics on the App Insights diagnostic via `azapi` so
  `llm-emit-token-metric` actually emits per-client token usage (azurerm exposes no
  argument for this; without it the App ID chargeback dimension was silently empty).

### Fixed

- Content-safety embeddings check is now anchored to the request **path suffix**
  (was an unanchored substring match, so a deployment named `embeddings` could be
  used to bypass Prompt Shield).
- Content safety now runs **before** the semantic cache, so cache hits are still
  screened by Prompt Shield (previously cache hits could bypass screening).
- Per-tier policies render from `var.tiers` so a third+ tier is admitted by the JWT
  fragment and rate/token-limited correctly (previously a new tier 401'd at runtime).
- Data-residency Azure Policy is an allowlist (`notIn`), closing the gap where
  non-regional SKUs like `GlobalBatch` slipped past the old denylist.
- `azuremonitor` logger created explicitly so per-API LLM diagnostics don't fail on a
  fresh instance; semantic-cache `cache_location` derived from `var.location`.
