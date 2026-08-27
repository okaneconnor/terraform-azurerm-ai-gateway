# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

- **Admission is now a single Entra app role; tiers are limit presets, not roles**
  (#36). The gateway app defines ONE app role (`var.admission_app_role`, default
  `AI.Gateway.Standard`) that answers exactly one question — is this identity
  allowed to reach the gateway at all. `var.tiers` loses `app_role` and
  `display_name` and becomes pure named limit presets; the new `var.default_tier`
  selects which preset applies to admitted callers (may be omitted with a single
  preset — the module never guesses between several). Why:
  - **One source of truth for tier.** Per-tier roles plus per-team config would be
    two competing authorities; with one admission role that conflict cannot exist,
    and the old "client holds several roles → highest tier wins" tie-break
    disappears with the ambiguity that forced it.
  - **Onboarding stops being a directory schema change.** Adding a tier used to
    mean a new app role on the gateway app (Graph-privileged); now it is config.
    Admission (directory, rarely changes) and consumption limits (config, changes
    often) get different owners, different privilege, different cadence.
  - Migration: assign every existing caller the admission role; move per-tier
    differentiation to the onboarding registry when it lands, or run distinct
    gateways per tier in the interim. BYO gateway apps must define one role whose
    value matches `admission_app_role` — its absence now fails the plan with a
    named error (`check.byo_admission_role`) instead of surfacing downstream.

### Added

- **Per-team overrides seam** (#39) — the registry becomes the authority on what
  each registered caller may do, without team changes ever planning the gateway:
  - The gateway creates two inert policy fragments (`ai-team-overrides`,
    `ai-team-content-safety`) with `ignore_changes` on their content; the
    onboarding submodule (given `apim_id` + the new contract outputs `tiers`,
    `canonical_models`, `rate_limit_renewal_seconds`, `content_safety_contract`)
    renders per-service policy from the merged registry and writes it via
    `azapi_update_resource`, with destroy-time twins resetting to inert.
  - **Merge semantics** — most specific wins, maps per key, lists wholesale:
    `limits` service → team → the team's tier preset; `allowed_models`
    service → team → `defaults.yaml` → all canonical models; content-safety
    categories/thresholds service → team → `defaults.yaml` → platform settings.
    `shield_prompt` / `enforce_on_completions` stay platform decisions; full
    per-team opt-out sits behind `allow_team_content_safety_opt_out`
    (default `false`); `limit_maxima` optionally caps effective limits.
  - **Model allowlist**: 403 `model_not_permitted` on the facade when a
    registered caller requests a canonical model outside its list.
  - **Fail closed**: with the seam active, an admitted caller absent from the
    registry gets **403 `not_onboarded`** — otherwise not registering would
    bypass allowlists and content-safety overrides. Inert seam (no registry
    management) keeps today's tier-preset behaviour exactly.
  - **`ai-cs-normalize`**: content-safety *category* blocks short-circuit with
    APIM's native `{"statusCode":403,...}` body and never raise `on-error` (only
    shield blocks do), so an outbound normaliser rewrites them to the
    `content_filtered` taxonomy body — closing a gap that predates this change.
  - Tier/platform-CS fragments gain guards (`team-policied`,
    `team-cs-policied`) so exactly one authority applies per caller; limit
    policies inside `<choose>` branches were doc- and live-verified to count
    per branch. 16 new plan-time validation rules with named-entry messages;
    `effective_policies` output as the merged audit view.

- **Versioned facade `/v1/chat/completions`** (#38) — the gateway's recommended
  consumer contract, decoupling callers from Azure's surface in both directions:
  - **Model indirection**: callers request canonical names; `var.model_map` maps
    them to deployments (default: identity map, zero-config). Deployments and
    model versions can churn as gateway config without a consumer migration.
    Unknown canonical name → explicit **404 `model_not_found`**, never a silent
    empty rewrite surfacing as a confusing backend error.
  - **Gateway-pinned api-version** (`var.aoai_api_version`): facade callers never
    send one, so an api-version bump is gateway config, not a consumer change.
  - **Streaming passes through** (`stream: true` → SSE) — documented in the
    OpenAPI 3.1 spec shipped at `specs/ai-gateway-v1.yaml`.
  - **Stable error taxonomy, gateway-wide**: a shared `ai-error-taxonomy`
    fragment maps every known failure to `{"error":{"message","type","code"}}`
    with `x-correlation-id` and `Retry-After` on 429s — codes: `invalid_token`,
    `missing_caller_id`, `invalid_request`, `model_not_found`,
    `content_filtered`, `rate_limit_exceeded`, `token_quota_exceeded`. Status
    codes are unchanged from pre-taxonomy behaviour; only bodies and headers
    gained structure. Wired into on-error of BOTH LLM surfaces; unknown errors
    deliberately fall through rather than being masked by a catch-all.
  - The raw `/openai` passthrough remains as the compatibility surface behind
    `enable_legacy_openai_path` (default `true`; `moved` blocks keep existing
    state addresses intact).
- **`modules/onboarding` — declarative team registry in its own state** (#37).
  Teams live in one reviewed YAML file (`registry_file`); applying the submodule
  reconciles one admission-role assignment per service identity. The module holds
  azuread resources only and couples to the gateway through three outputs, so an
  onboarding apply needs Entra permissions — never gateway credentials — and can
  never plan the gateway. Fourteen plan-time validation rules each fail with a
  message naming the offending entry: unknown-key typo guard, placeholder-GUID
  detection, derived-key hyphen-ambiguity collisions, identity-claimed-once
  (client id and principal), tier-must-exist-on-the-gateway, and the rest — every
  rule carries a failing-case unit test (13-run suite,
  `terraform -chdir=modules/onboarding test`, wired into CI). `examples/onboarding`
  ships the two-state layout, and `docs/onboarding.md` now leads with the
  registry as the recommended path.
- **BYO admission-role guard hard-fails the plan** — the `gateway_app_role_id`
  output gained a precondition; the `check` introduced with #36 only warns in a
  real plan (checks hard-fail only under `terraform test`), and a consumer
  onboarding state must never receive a null role id.
- **Consumer-integration outputs for out-of-state onboarding** (#36):
  `gateway_app_object_id` and `gateway_app_role_id` — exactly the two values an
  external `azuread_app_role_assignment` needs, resolved identically in
  module-created and `existing_gateway_app` modes (BYO resolves through a service
  principal data source). Plus `admission_app_role` and `tier_names` for
  registry validation. Team onboarding can now live in its own tiny Terraform
  state with Entra-only credentials — an onboarding apply can never plan the
  gateway. `docs/onboarding.md` is rewritten around that path, and its Graph
  examples now use the `appRoleAssignedTo` relationship of the resource service
  principal (the form Microsoft Graph documents for app-role grants).

- **Every resource is renamed onto the Azure CAF naming convention** (#42), and the
  random name suffix is gone. Names are now `<type>-<name_prefix>[-<environment>][-<region>][-<instance>]`
  with the CAF resource-type abbreviation **first** (`apim-aigw-uks`, `rg-aigw-uks`,
  `kv-aigw-uks`), so every name is predictable before apply — you can pre-create
  policy, RBAC, DNS and firewall rules against it, and two applies of the same config
  produce identical names.
  - `var.name_suffix` is **removed**. It generated a random 5-char token when unset,
    which made names unpredictable and forced a fresh suffix on every rebuild. Use the
    new `var.instance` to disambiguate side-by-side deployments.
  - New inputs: `var.environment` (optional CAF environment token), `var.instance`
    (optional instance token), and `var.custom_names` (per-resource name overrides).
  - Three abbreviations corrected against the [CAF table](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/resource-abbreviations):
    Foundry accounts `fdry` → **`aif`**, private endpoints `pe` → **`pep`**, Managed
    Redis `redis` → **`amr`**.
  - **The module no longer generates anything random, so the caller owns uniqueness**
    for globally-scoped names (APIM, Key Vault, the Foundry subdomain, API Center,
    Managed Redis, the public-IP DNS label) — the same contract CAF and Azure Verified
    Modules assume. Use a distinctive `name_prefix`, or `instance`, or `custom_names`.
  - Composed names are asserted against their Azure length cap at plan time (the
    `name_lengths` check) rather than silently truncated, because a clipped name can
    collide with another deployment's clipped name and surface as a confusing
    "already exists" at apply. The failure message names the input to change.
  - Renaming is a **replace**, not an in-place update. `docs/upgrading-v2.md` covers
    the three paths, including adopting v2 **without renaming anything** by pinning
    existing names in `custom_names`.

### Added

- `docs/naming.md` — the convention, the token table, every name a default deployment
  produces, the scoped-child exceptions, the length caps, and the uniqueness contract.
- `docs/upgrading-v2.md` — v1 → v2 migration, with the blast radius of each path
  stated honestly.

### Changed

- **Static analysis moved from `tfsec` to `trivy`** (pre-commit + CI). Aqua Security
  has retired tfsec in favour of Trivy, and tfsec's HCL parser predates Terraform 1.5
  `check` blocks — it fails outright on the new `name_lengths` check rather than
  reporting a finding. Trivy scans the module clean. Checkov is unchanged.

### Fixed

- **Caller identity is no longer derived from `azp` alone** (#34). `caller-app-id` is the
  counter-key for the per-tier rate limit and token limit/quota, and the `vary-by` for the
  semantic cache. It read only `azp` — a **v2.0** claim — and defaulted to an empty string,
  so a v1.0 token (which carries `appid` instead) would have put that caller into a single
  shared bucket: shared limits, and a shared cache partition that could serve one caller
  another's completion, all while returning 200. The fragment now reads `azp` and falls
  back to `appid`, and **fails closed with 403** if neither claim is present, so no caller
  can occupy the empty key. Module-created gateway apps request v2 tokens (verified live —
  even a managed identity fetching a token the v1/IMDS way receives a v2 token with `azp`),
  so the exposure was mainly `existing_gateway_app` with a v1 manifest; the guard removes
  the class of failure regardless of cause.

### Added

- **Onboarding via managed identity** is documented and verified end to end in
  `docs/onboarding.md` — a user-assigned identity granted a tier role authenticates with
  no client secret and is limited under its own identity. Note the portal cannot assign
  app-roles to managed identities; use the documented Graph/CLI path.
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
- **Backend-pool member removal**: removing or swapping a pool member failed with
  `Backend Entity ... is referenced in Backend Pool ... and cannot be deleted` — Terraform
  destroys the member's backend before updating the pool (a by-design core limitation,
  hashicorp/terraform#32153). Each member now gets a destroy-time cleanup action that
  detaches it from the pool first, so add / remove / swap — including removing several
  members in one apply — all converge in a single apply (live-verified).
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
