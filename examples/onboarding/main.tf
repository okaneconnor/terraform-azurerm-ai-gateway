# Two-state layout: the gateway lives in its own state (see examples/complete);
# this tiny configuration is the ONLY thing a team-onboarding pipeline applies.
# It needs Entra permissions and three gateway outputs — no gateway credentials.

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azuread" {}

# In a real estate these come from the gateway's remote state:
#
#   data "terraform_remote_state" "gateway" { ... }
#   gateway_app_object_id = data.terraform_remote_state.gateway.outputs.gateway_app_object_id
#
# Variables keep this example backend-agnostic.
variable "gateway_app_object_id" { type = string }
variable "gateway_app_role_id" { type = string }
variable "tier_names" { type = list(string) }

module "onboarding" {
  source = "../../modules/onboarding"

  registry_file         = "${path.module}/teams.yaml"
  gateway_app_object_id = var.gateway_app_object_id
  gateway_app_role_id   = var.gateway_app_role_id
  tier_names            = var.tier_names
}

output "onboarded_services" {
  value = module.onboarding.onboarded_services
}
