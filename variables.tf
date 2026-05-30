variable "subscription_id" {
  description = "Target Azure subscription ID (kns-platforms-pod-mcp work subscription)."
  type        = string
  default     = "230414f6-3458-4f1a-9f5c-488281e13c14"
}

variable "location" {
  description = "Azure region for all resources. Note: verify model + Content Safety availability for your region."
  type        = string
  default     = "uksouth"
}

variable "name_prefix" {
  description = "Short prefix for resource names (lowercase, no spaces)."
  type        = string
  default     = "aigw"
}

variable "publisher_name" {
  description = "APIM publisher organisation name."
  type        = string
  default     = "AI Platform Team"
}

variable "publisher_email" {
  description = "APIM publisher contact email."
  type        = string
  default     = "ai-platform@example.com"
}

variable "teams" {
  description = "Consumer teams that each get an APIM product + subscription. Map of team key to TPM limit."
  type = map(object({
    display_name      = string
    tokens_per_minute = number
    monthly_quota     = number
  }))
  default = {
    "team-alpha" = { display_name = "Team Alpha", tokens_per_minute = 1000, monthly_quota = 1000000 }
    "team-beta"  = { display_name = "Team Beta", tokens_per_minute = 500, monthly_quota = 500000 }
  }
}

variable "chat_model" {
  description = "Chat model deployment."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "gpt-4o"
    version  = "2024-08-06"
    sku_name = "GlobalStandard"
    capacity = 30
  }
}

variable "embedding_model" {
  description = "Embedding model deployment (used by semantic caching)."
  type = object({
    name     = string
    version  = string
    sku_name = string
    capacity = number
  })
  default = {
    name     = "text-embedding-3-small"
    version  = "1"
    sku_name = "Standard"
    capacity = 10
  }
}

variable "existing_mcp_server_url" {
  description = "Base URL of an existing remote MCP server to govern through the gateway."
  type        = string
  default     = "https://learn.microsoft.com/api/mcp"
}
