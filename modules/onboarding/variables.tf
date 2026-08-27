variable "registry_file" {
  description = <<-EOT
    Path to the team registry YAML — the declarative record of every team and
    service admitted to the gateway. Teams onboard, change and offboard by pull
    request against this one file; applying this module reconciles the
    assignments. See the module README for the schema.
  EOT
  type        = string
}

variable "gateway_app_object_id" {
  description = "The gateway module's `gateway_app_object_id` output — the service principal the admission role lives on."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.gateway_app_object_id))
    error_message = "gateway_app_object_id must be a GUID (the gateway module's gateway_app_object_id output)."
  }
}

variable "gateway_app_role_id" {
  description = "The gateway module's `gateway_app_role_id` output — the admission app role assigned to every onboarded service identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.gateway_app_role_id))
    error_message = "gateway_app_role_id must be a GUID (the gateway module's gateway_app_role_id output)."
  }
}

variable "tier_names" {
  description = "The gateway module's `tier_names` output — the preset names a team's `tier` may reference. Validated at plan so a registry can never point at a preset the gateway does not define."
  type        = list(string)

  validation {
    condition     = length(var.tier_names) > 0
    error_message = "tier_names must not be empty — pass the gateway module's tier_names output."
  }
}

# ---- Overrides seam (optional). Setting apim_id activates it: the module then
# renders per-team policy from the registry and writes it into the gateway's
# ai-team-overrides / ai-team-content-safety fragments via azapi.

variable "apim_id" {
  description = <<-EOT
    The gateway module's `apim_id` output. When set, this module owns the
    content of the gateway's team-override policy fragments: every registered
    service gets its own limits, model allowlist and (optionally) content-safety
    rendering, and callers absent from the registry are refused with
    403 not_onboarded. When null (default), the module manages Entra role
    assignments only and the gateway's tier presets apply to every caller.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.apim_id == null || can(regex("(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.ApiManagement/service/[^/]+$", var.apim_id))
    error_message = "apim_id must be an API Management service resource id (the gateway module's apim_id output)."
  }
}

variable "defaults_file" {
  description = <<-EOT
    Optional platform defaults YAML: `allowed_models` (list of canonical names)
    and/or `content_safety` (enabled, categories.{hate,self_harm,sexual,violence}
    .{enabled,threshold}). Teams inherit these unless they override; maps merge
    per key, lists replace wholesale. Absent defaults fall back to every
    canonical model and the gateway's platform content-safety settings.
  EOT
  type        = string
  default     = null
}

variable "tier_limits" {
  description = "The gateway module's `tiers` output. A team's `tier` selects its preset here as the base its limit overrides merge onto. Required when apim_id is set."
  type = map(object({
    tokens_per_minute  = number
    rate_limit_calls   = number
    token_quota        = optional(number)
    token_quota_period = optional(string, "Monthly")
  }))
  default = null
}

variable "canonical_models" {
  description = "The gateway module's `canonical_models` output — the names an allowed_models list may contain, and the default allowlist when none is declared. Required when apim_id is set."
  type        = list(string)
  default     = null
}

variable "rate_limit_renewal_seconds" {
  description = "The gateway module's `rate_limit_renewal_seconds` output — team rate limits share the tier presets' window."
  type        = number
  default     = 60

  validation {
    condition     = var.rate_limit_renewal_seconds >= 1 && var.rate_limit_renewal_seconds <= 300
    error_message = "rate_limit_renewal_seconds must be 1-300 (rate-limit-by-key renewal-period bounds)."
  }
}

variable "content_safety" {
  description = "The gateway module's `content_safety_contract` output. Required only when the registry or defaults declare content_safety overrides. shield_prompt and enforce_on_completions are platform decisions — teams tune categories and thresholds only."
  type = object({
    backend_name           = string
    shield_prompt          = optional(bool, true)
    enforce_on_completions = optional(bool, false)
    category_threshold     = optional(number, 4)
  })
  default = null
}

variable "allow_team_content_safety_opt_out" {
  description = "Permit registry entries to set content_safety.enabled = false (skipping ALL screening, Prompt Shield included, for that caller). Off by default: screening is a platform guarantee."
  type        = bool
  default     = false
}

variable "limit_maxima" {
  description = "Optional guardrail ceilings. When set, every service's EFFECTIVE (post-merge) limits must stay at or below these — a team PR raising a limit past a ceiling fails at plan."
  type = object({
    rate_limit_calls   = optional(number)
    tokens_per_minute  = optional(number)
    token_quota        = optional(number)
    token_quota_period = optional(string, "Monthly")
  })
  default = null
}

variable "model_map" {
  description = "The gateway module's `model_map` output — canonical name to deployment. Required when a registry or defaults file declares allowed_models, so the allowlist binds on the legacy /openai surface too (it addresses deployments, not canonical names)."
  type        = map(string)
  default     = null
}
