# The "complete" example exposes every tunable value as its OWN variable so a
# consumer can override anything from the command line / a tfvars file WITHOUT
# editing main.tf — nothing is hardcoded here. Defaults mirror the module defaults;
# change them per deployment.

variable "subscription_id" {
  description = "Target Azure subscription."
  type        = string
}

variable "location" {
  description = "Azure region (must offer your models with the deployment SKUs you allow)."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Short lowercase prefix for resource names."
  type        = string
  default     = "aigw"
}

variable "publisher_name" {
  description = "APIM publisher name."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "APIM publisher email."
  type        = string
  default     = "admin@example.com"
}

variable "allowed_client_cidrs" {
  description = "Client CIDRs allowed through the gateway IP filter."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ── API Management ──
variable "apim_sku_name" {
  description = "APIM SKU (Developer_1 or Premium_N)."
  type        = string
  default     = "Developer_1"
}

variable "apim_virtual_network_type" {
  description = "External (public gateway IP) or Internal (front with App Gateway/WAF)."
  type        = string
  default     = "External"
}

variable "apim_sampling_percentage" {
  description = "APIM App Insights diagnostic sampling percentage."
  type        = number
  default     = 100
}

# ── Models ──
variable "foundry_account_sku" {
  description = "SKU for the Foundry (AIServices) Cognitive account."
  type        = string
  default     = "S0"
}

variable "model_deployments" {
  description = "Model deployments on the Foundry account, keyed by deployment name."
  type = map(object({
    model_name    = string
    model_version = string
    sku_name      = optional(string, "Standard")
    capacity      = optional(number, 10)
    model_format  = optional(string, "OpenAI")
  }))
  default = {
    "gpt-4.1-mini" = {
      model_name    = "gpt-4.1-mini"
      model_version = "2025-04-14"
      sku_name      = "Standard"
      capacity      = 10
    }
    "text-embedding-ada-002" = {
      model_name    = "text-embedding-ada-002"
      model_version = "2"
      sku_name      = "Standard"
      capacity      = 50
    }
  }
}

# ── Tiers ──
variable "tiers" {
  description = "Consumption tiers — adding an entry creates an Entra app role + policy branches."
  type = map(object({
    display_name      = string
    app_role          = string
    tokens_per_minute = number
    rate_limit_calls  = number
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
    "ai-premium" = {
      display_name      = "AI Premium"
      app_role          = "AI.Gateway.Premium"
      tokens_per_minute = 500000
      rate_limit_calls  = 300
    }
  }
}

# ── Semantic cache ──
variable "semantic_cache_enabled" {
  description = "Enable Redis semantic caching."
  type        = bool
  default     = true
}

variable "redis_sku_name" {
  description = "Azure Managed Redis SKU for the semantic cache."
  type        = string
  default     = "Balanced_B0"
}

variable "redis_high_availability" {
  description = "Replicated (HA) Redis for production."
  type        = bool
  default     = false
}

variable "semantic_cache_score_threshold" {
  description = "Similarity threshold (lower = stricter)."
  type        = number
  default     = 0.05
}

variable "semantic_cache_duration_seconds" {
  description = "Cached completion TTL."
  type        = number
  default     = 120
}

# ── Content safety ──
variable "content_safety_enabled" {
  description = "Enable Prompt Shield + content moderation."
  type        = bool
  default     = true
}

variable "content_safety_category_threshold" {
  description = "Content Safety severity threshold (0-7)."
  type        = number
  default     = 4
}

# ── Circuit breaker ──
variable "circuit_breaker_trip_on_429" {
  description = "Trip the breaker on 429 (only sensible with a multi-member pool)."
  type        = bool
  default     = false
}

# ── Governance ──
variable "allowed_deployment_skus" {
  description = "Model-deployment SKUs permitted by the residency guardrail."
  type        = list(string)
  default     = ["Standard"]
}

# ── Key Vault ──
variable "key_vault_enabled" {
  description = "Deploy a private Key Vault for consumer workloads."
  type        = bool
  default     = true
}

variable "key_vault_sku_name" {
  description = "Key Vault SKU (standard or premium)."
  type        = string
  default     = "standard"
}

variable "key_vault_soft_delete_retention_days" {
  description = "Key Vault soft-delete retention."
  type        = number
  default     = 90
}

# ── Observability ──
variable "log_analytics_sku" {
  description = "Log Analytics workspace SKU."
  type        = string
  default     = "PerGB2018"
}

variable "log_retention_days" {
  description = "Log Analytics retention."
  type        = number
  default     = 30
}

# ── Toggles ──
variable "enable_api_center" {
  description = "Deploy API Center cataloguing."
  type        = bool
  default     = true
}

variable "enable_workbook" {
  description = "Deploy the Azure Monitor workbook."
  type        = bool
  default     = true
}

variable "create_demo_clients" {
  description = "Create one demo client app per tier (for the test scripts)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload  = "ai-gateway"
    example   = "complete"
    ManagedBy = "Terraform"
  }
}
