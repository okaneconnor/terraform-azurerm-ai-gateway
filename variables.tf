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

# --- Phase toggles (apply capabilities one at a time) ---

variable "enable_token_governance" {
  description = "Phase 2: token-limit + emit-token-metric + retry + circuit breaker."
  type        = bool
  default     = false
}

variable "enable_semantic_cache" {
  description = "Phase 3: Azure Managed Redis external cache + semantic cache policies."
  type        = bool
  default     = false
}

variable "enable_content_safety" {
  description = "Phase 4: Azure AI Content Safety account + llm-content-safety policy."
  type        = bool
  default     = false
}

variable "enable_mcp" {
  description = "Phase 5: MCP server (REST->MCP) + governed external MCP server (azapi)."
  type        = bool
  default     = false
}

variable "enable_agents_selfservice" {
  description = "Phase 6: A2A agent API + API Center catalog (azapi)."
  type        = bool
  default     = false
}

variable "existing_mcp_server_url" {
  description = "Phase 5: base URL of an existing remote MCP server to govern (e.g. https://learn.microsoft.com/api/mcp)."
  type        = string
  default     = "https://learn.microsoft.com/api/mcp"
}
