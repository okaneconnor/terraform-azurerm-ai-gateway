# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
