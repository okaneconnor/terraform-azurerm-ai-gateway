# Minimal deployment: defaults everywhere. You get a private, Entra-keyless AI
# gateway in front of gpt-4.1-mini + four AI services, with semantic caching,
# content safety, tiering, and full observability.

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
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email
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
