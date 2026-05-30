locals {
  ip_from = cidrhost(var.home_ip_cidr, 0)
  ip_to   = cidrhost(var.home_ip_cidr, -1)
}

resource "azurerm_api_management_policy_fragment" "ip_allow" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-ip-allow"
  format            = "xml"
  value             = templatefile("${path.module}/policies/frag-ip-allow.xml", { ip_from = local.ip_from, ip_to = local.ip_to })
}

resource "azurerm_api_management_policy_fragment" "entra_jwt" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-auth-entra-jwt"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-entra-jwt.xml", {
    tenant_id         = local.tenant_id
    gateway_client_id = azuread_application.gateway.client_id
  })
}

resource "azurerm_api_management_policy_fragment" "backend_mi" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-backend-managed-identity"
  format            = "xml"
  value             = file("${path.module}/policies/frag-backend-mi.xml")
}

resource "azurerm_api_management_policy_fragment" "content_safety" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-content-safety"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-content-safety.xml", {
    cs_backend_id = azurerm_api_management_backend.safety.name
  })
}

resource "azurerm_api_management_policy_fragment" "token_metric" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-token-metrics"
  format            = "xml"
  value             = file("${path.module}/policies/frag-token-metric.xml")
}
