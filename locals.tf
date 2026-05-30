resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

locals {
  suffix     = random_string.suffix.result
  rg_name    = "${var.name_prefix}-sandbox-rg"
  apim_name  = "${var.name_prefix}-apim-${local.suffix}"
  aoai_name  = "${var.name_prefix}-aoai-${local.suffix}"
  cs_name    = "${var.name_prefix}-cs-${local.suffix}"
  law_name   = "${var.name_prefix}-law-${local.suffix}"
  ai_name    = "${var.name_prefix}-appi-${local.suffix}"
  redis_name = "${var.name_prefix}-redis-${local.suffix}"
  apic_name  = "${var.name_prefix}-apic-${local.suffix}"

  # Managed identity audience for Azure AI / OpenAI backends.
  cognitive_resource_audience = "https://cognitiveservices.azure.com"

  # Default per-API governance limits for the sandbox (per-team overrides live on product policies).
  default_tpm   = 2000
  default_quota = 2000000

  openai_api_policy_file = (
    var.enable_content_safety ? "${path.module}/policies/llm-content-safety.xml" :
    var.enable_semantic_cache ? "${path.module}/policies/llm-semantic-cache.xml" :
    var.enable_token_governance ? "${path.module}/policies/llm-governance.xml" :
    "${path.module}/policies/llm-foundation.xml"
  )
}
