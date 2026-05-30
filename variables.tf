variable "subscription_id" {
  description = "Target Azure subscription ID (kns-platforms-pod-mcp work subscription)."
  type        = string
  default     = "230414f6-3458-4f1a-9f5c-488281e13c14"
}

variable "location" {
  description = "Azure region. UK South for HMCTS data residency."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Short prefix for resource names (lowercase)."
  type        = string
  default     = "aigw"
}

variable "publisher_name" {
  type    = string
  default = "HMCTS AI Tiger Team"
}

variable "publisher_email" {
  type    = string
  default = "ai-platform@example.com"
}

variable "home_ip_cidr" {
  description = "Single client CIDR allowed to reach the gateway (e.g. office egress). Express as from/to in policy."
  type        = string
  default     = "0.0.0.0/0" # tighten before real use; 0.0.0.0/0 = allow all (sandbox only)
}

variable "vnet_cidr" {
  type    = string
  default = "10.90.0.0/16"
}
variable "apim_subnet_cidr" {
  type    = string
  default = "10.90.1.0/24"
}
variable "pe_subnet_cidr" {
  type    = string
  default = "10.90.2.0/24"
}

variable "chat_model" {
  description = "Foundry chat model. gpt-4.1-mini Standard is the current GA model available in-region (UK) per Foundry region availability."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "gpt-4.1-mini"
    version  = "2025-04-14"
    sku_name = "Standard" # in-UK processing; do NOT use GlobalStandard/DataZoneStandard for HMCTS data
    capacity = 10
  }
}

variable "products" {
  description = "Self-service consumption tiers (keyless; limits keyed by client app id)."
  type = map(object({
    display_name      = string
    app_role          = string
    tokens_per_minute = number
    rate_limit_calls  = number
  }))
  default = {
    "ai-sandbox" = {
      display_name      = "AI Sandbox", app_role = "AI.Gateway.Sandbox",
      tokens_per_minute = 20000, rate_limit_calls = 30
    }
    "ai-production-standard" = {
      display_name      = "AI Production Standard", app_role = "AI.Gateway.Production",
      tokens_per_minute = 150000, rate_limit_calls = 120
    }
  }
}

variable "rate_limit_renewal_seconds" {
  type    = number
  default = 60
}

variable "enable_mcp" {
  description = "Provision MCP governance (azapi). Kept from v1."
  type        = bool
  default     = true
}

variable "existing_mcp_server_url" {
  type    = string
  default = "https://learn.microsoft.com/api/mcp"
}
