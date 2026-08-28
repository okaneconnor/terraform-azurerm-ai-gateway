# Two-state layout: the gateway lives in its own state (see examples/complete);
# this configuration is the ONLY thing a team-onboarding pipeline applies.
# It reads the gateway's outputs — never its credentials — and applying it can
# never plan the gateway.

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

data "terraform_remote_state" "gateway" {
  backend = "azurerm"

  config = {
    resource_group_name  = var.gateway_state.resource_group_name
    storage_account_name = var.gateway_state.storage_account_name
    container_name       = var.gateway_state.container_name
    key                  = var.gateway_state.key
  }
}

variable "gateway_state" {
  description = "Where the gateway's Terraform state lives — the only coupling between the two states."
  type = object({
    resource_group_name  = string
    storage_account_name = string
    container_name       = string
    key                  = string
  })
}

variable "enforce_team_policy" {
  description = <<-EOT
    false: onboarding grants admission only, and every admitted caller gets the
    gateway's default tier preset (v1 behaviour).

    true: the registry also becomes the authority on each caller's limits, model
    allowlist and content-safety settings. Note this is FAIL CLOSED — once on, a
    caller holding the admission role but absent from teams.yaml is refused with
    403 not_onboarded, so register every existing caller before enabling it.
  EOT
  type        = bool
  default     = true
}

module "onboarding" {
  source = "../../modules/onboarding"

  registry_file = "${path.module}/teams.yaml"

  gateway_app_object_id = data.terraform_remote_state.gateway.outputs.gateway_app_object_id
  gateway_app_role_id   = data.terraform_remote_state.gateway.outputs.gateway_app_role_id
  tier_names            = data.terraform_remote_state.gateway.outputs.tier_names

  # Everything below activates the overrides seam. Drop the whole block (or set
  # enforce_team_policy = false) to run admission-only.
  apim_id                    = var.enforce_team_policy ? data.terraform_remote_state.gateway.outputs.apim_id : null
  tier_limits                = data.terraform_remote_state.gateway.outputs.tiers
  canonical_models           = data.terraform_remote_state.gateway.outputs.canonical_models
  model_map                  = data.terraform_remote_state.gateway.outputs.model_map
  rate_limit_renewal_seconds = data.terraform_remote_state.gateway.outputs.rate_limit_renewal_seconds
  content_safety             = data.terraform_remote_state.gateway.outputs.content_safety_contract
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
