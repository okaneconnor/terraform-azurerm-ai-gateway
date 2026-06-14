# "Complete" example: every tunable value is driven from this example's own
# variables (see variables.tf) — nothing is hardcoded here, so a consumer can
# override anything via -var / a tfvars file without editing this file.
#
# To inject into an existing landing-zone network instead of creating one, add:
#   existing_network              = { vnet_id = "...", apim_subnet_id = "...", pe_subnet_id = "..." }
#   existing_private_dns_zone_ids = { cognitive = "...", openai = "...", ... }   # if hub-managed DNS
# and to centralise logs:
#   existing_log_analytics_workspace_id = "..."
#   existing_application_insights        = { id = "...", connection_string = "..." }

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.74"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azuread" {}

module "ai_gateway" {
  source = "../.."

  location        = var.location
  name_prefix     = var.name_prefix
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email
  tags            = var.tags

  # API Management
  apim_sku_name             = var.apim_sku_name
  apim_virtual_network_type = var.apim_virtual_network_type
  apim_diagnostic = {
    sampling_percentage = var.apim_sampling_percentage
  }
  allowed_client_cidrs = var.allowed_client_cidrs

  # Models
  foundry_account_sku = var.foundry_account_sku
  model_deployments   = var.model_deployments

  # Tiers
  tiers = var.tiers

  # AI gateway policies
  semantic_cache = {
    enabled           = var.semantic_cache_enabled
    redis_sku_name    = var.redis_sku_name
    high_availability = var.redis_high_availability
    score_threshold   = var.semantic_cache_score_threshold
    duration_seconds  = var.semantic_cache_duration_seconds
  }

  content_safety = {
    enabled            = var.content_safety_enabled
    category_threshold = var.content_safety_category_threshold
  }

  circuit_breaker = {
    trip_on_429 = var.circuit_breaker_trip_on_429
  }

  deployment_sku_policy = {
    allowed_sku_names = var.allowed_deployment_skus
  }

  # Key Vault
  key_vault = {
    enabled                    = var.key_vault_enabled
    sku_name                   = var.key_vault_sku_name
    soft_delete_retention_days = var.key_vault_soft_delete_retention_days
  }

  # Observability
  log_analytics_sku  = var.log_analytics_sku
  log_retention_days = var.log_retention_days

  # Toggles
  enable_api_center   = var.enable_api_center
  enable_workbook     = var.enable_workbook
  create_demo_clients = var.create_demo_clients
}

output "apim_gateway_url" {
  value = module.ai_gateway.apim_gateway_url
}

output "gateway_app_client_id" {
  value = module.ai_gateway.gateway_app_client_id
}

output "tenant_id" {
  value = module.ai_gateway.tenant_id
}

output "demo_clients" {
  value     = module.ai_gateway.demo_clients
  sensitive = true
}

output "resource_group_name" {
  value = module.ai_gateway.resource_group_name
}

output "foundry_account_name" {
  value = module.ai_gateway.foundry_account_name
}

output "foundry_endpoint" {
  value = module.ai_gateway.foundry_endpoint
}

output "model_deployment_names" {
  value = module.ai_gateway.model_deployment_names
}

output "log_analytics_workspace_guid" {
  value = module.ai_gateway.log_analytics_workspace_guid
}

# Integration outputs — peering / granting the gateway access to your resources.
output "apim_principal_id" {
  value = module.ai_gateway.apim_principal_id
}

output "vnet_id" {
  value = module.ai_gateway.vnet_id
}

output "private_dns_zone_ids" {
  value = module.ai_gateway.private_dns_zone_ids
}
