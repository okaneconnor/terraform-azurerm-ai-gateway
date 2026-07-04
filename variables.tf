# ── Core ─────────────────────────────────────────────────────────────────────

variable "location" {
  description = "Azure region for all resources. Choose a region where your chat + embeddings models are available with the deployment SKUs you allow (see deployment_sku_policy)."
  type        = string
}

variable "name_prefix" {
  description = "Short lowercase prefix for resource names (e.g. \"aigw\", \"contoso-ai\")."
  type        = string
  default     = "aigw"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,14}$", var.name_prefix))
    error_message = "name_prefix must be 2-15 chars, lowercase alphanumeric/hyphens, starting with a letter (it feeds resource-name length limits, e.g. Key Vault's 24 chars)."
  }
}

variable "name_suffix" {
  description = "Override the random 5-char suffix appended to most resource names. Set this for deterministic / standards-compliant names (some orgs forbid randomness in names). Leave null to generate one."
  type        = string
  default     = null

  validation {
    condition     = var.name_suffix == null || can(regex("^[a-z0-9]{1,8}$", var.name_suffix))
    error_message = "name_suffix must be 1-8 lowercase alphanumeric chars."
  }
}

variable "tags" {
  description = "Tags applied to all taggable resources."
  type        = map(string)
  default     = {}
}

variable "existing_resource_group_name" {
  description = "Deploy into an existing resource group (landing-zone pattern) instead of creating one. The RG must already exist and be in var.location. Leave null to create one named <name_prefix>-<region>-rg."
  type        = string
  default     = null
}

# ── API Management ───────────────────────────────────────────────────────────

variable "publisher_name" {
  description = "APIM publisher name (shown in the developer portal)."
  type        = string
}

variable "publisher_email" {
  description = "APIM publisher email."
  type        = string
}

variable "apim_sku_name" {
  description = <<-EOT
    APIM SKU (name_capacity). Default Developer_1 (cheap, no SLA, no zones).
    VNet INJECTION (this module's private model) is supported ONLY on classic
    Developer and Premium — NOT on classic Basic/Standard.
    For production use Premium_1+ (SLA, zone redundancy, multi-region).
  EOT
  type        = string
  default     = "Developer_1"

  validation {
    condition     = can(regex("^(Developer_1|Premium_[0-9]+)$", var.apim_sku_name))
    error_message = "apim_sku_name must be Developer_1 (capacity 1 only) or Premium_N — the only classic tiers that support VNet injection."
  }
}

variable "apim_virtual_network_type" {
  description = <<-EOT
    APIM VNet injection mode. "External" (default) gives APIM a public gateway IP
    inside the VNet. "Internal" removes the public endpoint entirely (no public
    gateway IP) — front it with Application Gateway / WAF for ingress and make sure
    your DNS resolves the internal gateway and the APIM subnet NSG permits it.
  EOT
  type        = string
  default     = "External"

  validation {
    condition     = contains(["External", "Internal"], var.apim_virtual_network_type)
    error_message = "apim_virtual_network_type must be \"External\" or \"Internal\"."
  }
}

variable "apim_diagnostic" {
  description = "APIM Application Insights diagnostic tuning. sampling_percentage 100 captures every request (lower it to cut cost/volume at scale); verbosity is information | verbose | error."
  type = object({
    sampling_percentage = optional(number, 100)
    verbosity           = optional(string, "information")
  })
  default = {}

  validation {
    condition     = var.apim_diagnostic.sampling_percentage >= 0 && var.apim_diagnostic.sampling_percentage <= 100
    error_message = "apim_diagnostic.sampling_percentage must be between 0 and 100."
  }
  validation {
    condition     = contains(["information", "verbose", "error"], var.apim_diagnostic.verbosity)
    error_message = "apim_diagnostic.verbosity must be information, verbose, or error."
  }
}

variable "allowed_client_cidrs" {
  description = "Client CIDRs allowed through the gateway's IP filter (e.g. office egress ranges). The default allows all — tighten before real use; Entra JWT auth remains mandatory regardless."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.allowed_client_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid IPv4 CIDR."
  }
}

# ── Network ──────────────────────────────────────────────────────────────────

variable "network" {
  description = "VNet and subnet CIDRs for the module-created network. Ignored when existing_network is set. APIM is injected into the apim subnet; all backends are reached via private endpoints in the pe subnet."
  type = object({
    vnet_cidr        = optional(string, "10.90.0.0/16")
    apim_subnet_cidr = optional(string, "10.90.1.0/24")
    pe_subnet_cidr   = optional(string, "10.90.2.0/24")
  })
  default = {}
}

variable "existing_network" {
  description = <<-EOT
    Bring-your-own VNet and subnets (landing-zone / hub-spoke adoption). When set,
    the module does NOT create the VNet, subnets, or NSG — it injects APIM into
    apim_subnet_id and places private endpoints in pe_subnet_id. You are then
    responsible for the APIM subnet's NSG rules (see README) and for the subnets
    being adequately sized and delegated. Leave null to create an isolated VNet
    from var.network.
  EOT
  type = object({
    vnet_id        = string
    apim_subnet_id = string
    pe_subnet_id   = string
  })
  default = null
}

variable "existing_private_dns_zone_ids" {
  description = <<-EOT
    Bring-your-own private DNS zones (hub-managed DNS). Map keyed by zone role —
    keys: cognitive, openai, aiservices, keyvault, redis — each a private DNS zone
    resource ID. When non-empty the module does NOT create any private DNS zones or
    VNet links and uses these IDs for private-endpoint DNS groups; provide every key
    for the backends you deploy. Leave empty to create + link them.
  EOT
  type        = map(string)
  default     = {}
}

# ── Observability (bring-your-own optional) ──────────────────────────────────

variable "existing_log_analytics_workspace_id" {
  description = "Bring-your-own Log Analytics workspace (Azure resource ID) for diagnostics — common when an org centralises logs. Leave null to create one."
  type        = string
  default     = null
}

variable "log_analytics_sku" {
  description = "SKU for the module-created Log Analytics workspace (ignored when existing_log_analytics_workspace_id is set)."
  type        = string
  default     = "PerGB2018"
}

variable "log_retention_days" {
  description = "Retention for the module-created Log Analytics workspace."
  type        = number
  default     = 30
}

variable "existing_application_insights" {
  description = "Bring-your-own Application Insights for APIM request/token telemetry. When set the module uses it instead of creating one (needs both the resource id and its connection string). Leave null to create one wired to the workspace."
  type = object({
    id                = string
    connection_string = string
  })
  default = null
}

variable "enable_workbook" {
  description = "Deploy the Azure Monitor workbook (token usage by client app, request volume)."
  type        = bool
  default     = true
}

# ── Model deployments (Foundry / Azure OpenAI) ───────────────────────────────

variable "foundry_account_sku" {
  description = "SKU for the Foundry (AIServices) Cognitive account that hosts your model deployments."
  type        = string
  default     = "S0"
}

variable "model_deployments" {
  description = <<-EOT
    Model deployments created on the Foundry (AIServices) account, keyed by
    deployment name (the key becomes the /openai/deployments/<name> path segment).
    REQUIRED — the module ships no default model: Azure deprecates model versions
    over time and SKU/region availability varies, so choosing current models is the
    consumer's responsibility. If semantic_cache is enabled, include the embeddings
    model named by semantic_cache.embeddings_deployment. model_format defaults to
    OpenAI (set e.g. "Meta"/"Mistral" for those). Each sku_name must be in
    deployment_sku_policy.allowed_sku_names while that policy is enabled. Concurrent
    deployments to one account can 409 transiently — re-apply or use -parallelism=1.
  EOT
  type = map(object({
    model_name    = string
    model_version = string
    sku_name      = optional(string, "Standard")
    capacity      = optional(number, 10)
    model_format  = optional(string, "OpenAI")
  }))

  validation {
    condition     = length(var.model_deployments) > 0
    error_message = "Provide at least one model deployment — this module ships no default model (Azure deprecates versions over time, so the choice is yours)."
  }

  validation {
    condition = !var.deployment_sku_policy.enabled || alltrue([
      for d in var.model_deployments : contains(var.deployment_sku_policy.allowed_sku_names, d.sku_name)
    ])
    error_message = "Every model deployment sku_name must be in deployment_sku_policy.allowed_sku_names while the SKU policy is enabled. Choose a model SKU in the allowlist, or add the SKU (note: Global*/DataZone* SKUs process data outside the deployment region — a residency trade-off)."
  }
}

# ── Consumption tiers ────────────────────────────────────────────────────────

variable "tiers" {
  description = <<-EOT
    Self-service consumption tiers (keyless model: limits keyed by the caller's
    Entra client app id). Each tier becomes an Entra app role on the gateway app
    AND a branch in the rate/token-limit policies, so adding an entry here is the
    complete change. Tokens-per-minute also bounds spend per client.
    The JWT policy admits only tokens carrying one of these app roles; when a
    client holds several, the highest tokens_per_minute tier wins.
  EOT
  type = map(object({
    display_name       = string
    app_role           = string
    tokens_per_minute  = number
    rate_limit_calls   = number
    token_quota        = optional(number)
    token_quota_period = optional(string, "Monthly")
  }))
  default = {
    "ai-sandbox" = {
      display_name      = "AI Sandbox"
      app_role          = "AI.Gateway.Sandbox"
      tokens_per_minute = 20000
      rate_limit_calls  = 30
    }
    "ai-production-standard" = {
      display_name      = "AI Production Standard"
      app_role          = "AI.Gateway.Production"
      tokens_per_minute = 150000
      rate_limit_calls  = 120
    }
  }

  validation {
    condition     = length(var.tiers) > 0
    error_message = "Define at least one tier."
  }
  validation {
    condition     = length(distinct([for t in var.tiers : t.app_role])) == length(var.tiers)
    error_message = "Each tier needs a unique app_role value."
  }
  validation {
    # Matches Entra's app-role value charset AND keeps the value safe to render into
    # the policy XML (no quotes / XML metacharacters that could break the fragment).
    condition     = alltrue([for t in var.tiers : can(regex("^[A-Za-z0-9._-]+$", t.app_role))])
    error_message = "Each tier app_role must match ^[A-Za-z0-9._-]+$ (Entra app-role value charset; no spaces or XML metacharacters)."
  }
  validation {
    condition = alltrue(flatten([
      for a in values(var.tiers)[*].app_role : [
        for b in values(var.tiers)[*].app_role : a == b || !strcontains(b, a)
      ]
    ]))
    error_message = "No tier's app_role may be a substring of another's (e.g. \"AI.Premium\" and \"AI.Premium2\") — the policy role check is a substring match on the comma-joined roles claim."
  }
  validation {
    condition     = alltrue([for t in var.tiers : contains(["Hourly", "Daily", "Weekly", "Monthly", "Yearly"], t.token_quota_period)])
    error_message = "Each tier token_quota_period must be one of Hourly, Daily, Weekly, Monthly, Yearly (llm-token-limit token-quota-period)."
  }
  validation {
    condition     = alltrue([for t in var.tiers : t.token_quota == null ? true : t.token_quota > 0])
    error_message = "Each tier token_quota, when set, must be greater than 0."
  }
}

variable "rate_limit_renewal_seconds" {
  description = "Fixed-window length for the per-tier request rate limit."
  type        = number
  default     = 60
}

# ── Optional AI services exposed through the gateway ─────────────────────────

variable "ai_services" {
  description = <<-EOT
    Cognitive Services exposed as passthrough APIs through the gateway, keyed by a
    short identifier. Add/remove/resize services freely — each entry creates the
    account (private, Entra-only), a private endpoint, an APIM backend + API with
    the standard policy chain (IP filter -> JWT -> rate limit -> managed identity).
    NOTE: content_safety.enabled requires an entry whose kind is "ContentSafety".
  EOT
  type = map(object({
    kind         = string
    sku_name     = string
    display_name = string
    api_path     = string
    short_name   = string # used in resource names; keep it brief
  }))
  default = {
    safety = {
      kind         = "ContentSafety"
      sku_name     = "S0"
      display_name = "Content Safety"
      api_path     = "contentsafety"
      short_name   = "cs"
    }
    speech = {
      kind         = "SpeechServices"
      sku_name     = "S0"
      display_name = "Speech"
      api_path     = "speech"
      short_name   = "spch"
    }
    language = {
      kind         = "TextAnalytics"
      sku_name     = "S"
      display_name = "Language"
      api_path     = "language"
      short_name   = "lang"
    }
    docintel = {
      kind         = "FormRecognizer"
      sku_name     = "S0"
      display_name = "Document Intelligence"
      api_path     = "docintel"
      short_name   = "doci"
    }
  }
}

# ── AI gateway policies ──────────────────────────────────────────────────────

variable "content_safety" {
  description = "Prompt screening via llm-content-safety (+ Prompt Shield). Runs BEFORE the semantic cache so every prompt is screened, including ones answered from cache. Requires an ai_services entry of kind ContentSafety. Set enforce_on_completions=true to ALSO screen model OUTPUTS (completions): non-streaming violations return 403; for streaming responses the handler buffers events and cuts the connection on a violation (no 403)."
  type = object({
    enabled                = optional(bool, true)
    shield_prompt          = optional(bool, true)
    category_threshold     = optional(number, 4) # 0-7; blocks at >= threshold severity
    enforce_on_completions = optional(bool, false)
  })
  default = {}
}

variable "semantic_cache" {
  description = <<-EOT
    Semantic caching of LLM completions in Azure Managed Redis (RediSearch),
    partitioned per client app. Caching is OPT-IN: it requires an Azure Managed
    Redis (RediSearch) instance that must be available in your region
    (provisioning was observed to fail in some regions), so it defaults off. Set
    enabled=true to use it, and include an embeddings model in model_deployments
    matching embeddings_deployment (used to vectorise prompts). score_threshold:
    lower = stricter similarity. Set high_availability=true for a production
    (replicated) cache.
  EOT
  type = object({
    enabled               = optional(bool, false)
    redis_sku_name        = optional(string, "Balanced_B0")
    high_availability     = optional(bool, false)
    score_threshold       = optional(number, 0.05)
    duration_seconds      = optional(number, 120)
    embeddings_deployment = optional(string, "text-embedding-ada-002")
  })
  default = {}

  validation {
    condition     = !var.semantic_cache.enabled || contains(keys(var.model_deployments), var.semantic_cache.embeddings_deployment)
    error_message = "semantic_cache.embeddings_deployment must be a key of model_deployments."
  }
}

variable "circuit_breaker" {
  description = <<-EOT
    Circuit breaker on the Foundry backend. Default trips on 5xx only: with a
    single-member pool, tripping on 429 lets one bursty client 503 the whole
    gateway for trip_duration (Microsoft's sample pattern does include 429 —
    set trip_on_429 = true if you run a multi-member pool where failover helps).
  EOT
  type = object({
    enabled            = optional(bool, true)
    failure_count      = optional(number, 3)
    interval           = optional(string, "PT1M")
    trip_duration      = optional(string, "PT1M")
    trip_on_429        = optional(bool, false)
    accept_retry_after = optional(bool, true)
  })
  default = {}
}

# ── Governance ───────────────────────────────────────────────────────────────

variable "deployment_sku_policy" {
  description = <<-EOT
    Azure Policy guardrail denying model-deployment SKUs outside the allowlist.
    The default ["Standard"] keeps inference in-region (data residency): Global*/
    DataZone* SKUs process data outside the deployment region and are denied.
    Extend the list (e.g. "ProvisionedManaged", "Batch") if regional processing
    under those SKUs fits your residency requirements.
  EOT
  type = object({
    enabled           = optional(bool, true)
    allowed_sku_names = optional(list(string), ["Standard"])
  })
  default = {}
}

variable "enable_api_center" {
  description = "Deploy an API Center service that continuously catalogues the gateway's APIs."
  type        = bool
  default     = true
}

# ── Key Vault (optional, for consumer workloads) ─────────────────────────────

variable "key_vault" {
  description = <<-EOT
    Optional private Key Vault (RBAC, purge protection, private endpoint) for
    consumer workloads' secrets — the gateway itself stores nothing in it. Set
    enabled=false to skip. SKU / retention / purge-protection are tunable for org
    policy (e.g. premium for HSM-backed keys).
  EOT
  type = object({
    enabled                    = optional(bool, true)
    sku_name                   = optional(string, "standard")
    soft_delete_retention_days = optional(number, 90)
    purge_protection_enabled   = optional(bool, true)
  })
  default = {}
}

# ── Entra ────────────────────────────────────────────────────────────────────

variable "existing_gateway_app" {
  description = <<-EOT
    Bring-your-own gateway app registration for tenants where Entra app creation
    is restricted. The app must: be single-tenant, request v2 access tokens, and
    define one Application app role per tier whose `value` matches tiers[*].app_role.
    Leave null (default) and the module creates and wires the app itself.
  EOT
  type = object({
    client_id = string
  })
  default = null
}

variable "create_demo_clients" {
  description = "Create one demo client app (with secret) per tier, role-assigned to that tier — handy for testing the gateway end-to-end. Off by default so real deployments don't ship unused credentials. Requires the module-created gateway app (not BYO)."
  type        = bool
  default     = false

  validation {
    condition     = !(var.create_demo_clients && var.existing_gateway_app != null)
    error_message = "create_demo_clients requires the module-created gateway app (existing_gateway_app must be null) so role assignments can reference its role IDs."
  }
}

