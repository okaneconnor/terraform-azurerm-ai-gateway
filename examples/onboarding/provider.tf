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