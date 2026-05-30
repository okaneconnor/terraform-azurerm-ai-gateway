resource "azurerm_api_management_backend" "foundry" {
  name                = "foundry-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = "${azurerm_cognitive_account.foundry.endpoint}openai"
}

resource "azurerm_api_management_backend" "safety" {
  name                = "content-safety-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["safety"].endpoint, "/")
}

resource "azurerm_api_management_backend" "speech" {
  name                = "speech-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["speech"].endpoint, "/")
}

resource "azurerm_api_management_backend" "language" {
  name                = "language-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["language"].endpoint, "/")
}

resource "azurerm_api_management_backend" "docintel" {
  name                = "docintel-backend"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  protocol            = "http"
  url                 = trimsuffix(azurerm_cognitive_account.svc["docintel"].endpoint, "/")
}

resource "azurerm_api_management_api" "foundry" {
  name                  = "foundry-openai"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = "Foundry (Azure OpenAI)"
  path                  = "openai"
  protocols             = ["https"]
  subscription_required = false

  import {
    content_format = "openapi+json-link"
    content_value  = "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  }
}

resource "azurerm_api_management_api_policy" "foundry" {
  api_name            = azurerm_api_management_api.foundry.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content         = file("${path.module}/policies/api-foundry.xml")
}

locals {
  ai_apis = {
    safety   = { display = "Content Safety", path = "contentsafety", backend = "content-safety-backend" }
    speech   = { display = "Speech", path = "speech", backend = "speech-backend" }
    language = { display = "Language", path = "language", backend = "language-backend" }
    docintel = { display = "Document Intelligence", path = "docintel", backend = "docintel-backend" }
  }
}

resource "azurerm_api_management_api" "svc" {
  for_each              = local.ai_apis
  name                  = "ai-${each.key}"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  revision              = "1"
  display_name          = each.value.display
  path                  = each.value.path
  protocols             = ["https"]
  subscription_required = false
}

resource "azurerm_api_management_api_policy" "svc" {
  for_each            = local.ai_apis
  api_name            = azurerm_api_management_api.svc[each.key].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  xml_content = templatefile("${path.module}/policies/api-aiservice.xml", {
    backend_id = each.value.backend
  })
}
