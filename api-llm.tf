resource "azurerm_api_management_api" "openai" {
  name                  = "openai"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = "Azure OpenAI"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = true

  import {
    content_format = "openapi+json-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  }
}

resource "azurerm_api_management_backend" "aoai" {
  name                = "aoai-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.aoai.endpoint}openai"
  resource_id         = azurerm_cognitive_account.aoai.id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }

  # circuit_breaker_rule schema confirmed against azurerm 4.74 registry docs:
  # attribute is accept_retry_after_enabled (not accept_retry_after); failure_condition
  # uses interval_duration (not interval). Trips on 3x 429/5xx within 1 minute, honours Retry-After.
  dynamic "circuit_breaker_rule" {
    for_each = var.enable_token_governance ? [1] : []
    content {
      name          = "aoai-breaker"
      trip_duration = "PT1M"
      failure_condition {
        count             = 3
        interval_duration = "PT1M"
        status_code_range {
          min = 429
          max = 429
        }
        status_code_range {
          min = 500
          max = 599
        }
      }
      accept_retry_after_enabled = true
    }
  }
}

resource "azurerm_api_management_backend" "embeddings" {
  count               = var.enable_semantic_cache ? 1 : 0
  name                = "embeddings-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.aoai.endpoint}openai/deployments/${azurerm_cognitive_deployment.embeddings.name}"
  resource_id         = azurerm_cognitive_account.aoai.id

  tls {
    validate_certificate_chain = true
    validate_certificate_name  = true
  }
}

# Composed API policy. The active fragment is selected by local.openai_api_policy_file
# based on which phase toggles are enabled. templatefile ignores unused vars, so passing
# the full variable set is safe for every fragment.
resource "azurerm_api_management_api_policy" "openai" {
  api_name            = azurerm_api_management_api.openai.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  xml_content = templatefile(local.openai_api_policy_file, {
    backend_id            = azurerm_api_management_backend.aoai.name
    tpm                   = local.default_tpm
    quota                 = local.default_quota
    embeddings_backend_id = var.enable_semantic_cache ? azurerm_api_management_backend.embeddings[0].name : ""
    cs_backend_id         = var.enable_content_safety ? azurerm_api_management_backend.content_safety[0].name : ""
  })
}
