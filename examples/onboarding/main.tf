# Two-state layout: the gateway lives in its own state (see examples/complete);
# this configuration is the ONLY thing a team-onboarding pipeline applies.
# It takes a handful of the gateway's outputs as inputs — never its credentials,
# and applying it can never plan the gateway.
#
# The values below are plain variables so this example stays backend-agnostic and
# so the onboarding pipeline reads nothing it does not need. Wire them however
# your estate passes values between states (CI variables, a shared tfvars file,
# or a terraform_remote_state data source if you already share state access —
# note that reading the gateway's state exposes ALL of its outputs, including
# sensitive ones, to whatever runs this).

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    # Only needed for the overrides seam (apim_id below). Admission-only
    # onboarding is azuread and nothing else.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azuread" {}
provider "azapi" {}

# Admission — all that is needed to grant access.
variable "gateway_app_object_id" { type = string }
variable "gateway_app_role_id" { type = string }
variable "tier_names" { type = list(string) }

# The overrides seam. Set apim_id to null to run admission-only, in which case
# every admitted caller gets the gateway's default tier preset (v1 behaviour).
variable "apim_id" {
  type    = string
  default = null
}
variable "tier_limits" {
  type    = map(any)
  default = null
}
variable "canonical_models" {
  type    = list(string)
  default = null
}
variable "model_map" {
  type    = map(string)
  default = null
}
variable "rate_limit_renewal_seconds" {
  type    = number
  default = 60
}
variable "content_safety" {
  type    = any
  default = null
}

module "onboarding" {
  source = "../../modules/onboarding"

  registry_file = "${path.module}/teams.yaml"

  gateway_app_object_id = var.gateway_app_object_id
  gateway_app_role_id   = var.gateway_app_role_id
  tier_names            = var.tier_names

  # Everything below activates the overrides seam. Leave apim_id null to run
  # admission-only. NOTE this is FAIL CLOSED — once on, a caller holding the
  # admission role but absent from teams.yaml is refused with 403 not_onboarded,
  # so register every existing caller before enabling it.
  apim_id                    = var.apim_id
  tier_limits                = var.tier_limits
  canonical_models           = var.canonical_models
  model_map                  = var.model_map
  rate_limit_renewal_seconds = var.rate_limit_renewal_seconds
  content_safety             = var.content_safety
  defaults_file              = "${path.module}/defaults.yaml"

  # Ceilings no team PR can exceed, whatever it writes in teams.yaml.
  limit_maxima = {
    rate_limit_calls   = 300
    tokens_per_minute  = 200000
    token_quota        = 20000000
    token_quota_period = "Monthly"
  }
}

output "onboarded_services" {
  description = "Every admitted service, keyed <team>-<service>."
  value       = module.onboarding.onboarded_services
}

output "effective_policies" {
  description = "The fully merged limits, allowlist and content-safety settings each service actually gets — the audit view."
  value       = module.onboarding.effective_policies
}
