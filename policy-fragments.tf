locals {
  ip_allow_ranges = [
    for c in var.allowed_client_cidrs : {
      from = cidrhost(c, 0)
      to   = cidrhost(c, -1)
    }
  ]
}

resource "azurerm_api_management_policy_fragment" "ip_allow" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-ip-allow"
  format            = "xml"
  value             = templatefile("${path.module}/policies/frag-ip-allow.xml", { ranges = local.ip_allow_ranges })
}

resource "azurerm_api_management_policy_fragment" "entra_jwt" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-auth-entra-jwt"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-entra-jwt.xml", {
    tenant_id         = local.tenant_id
    gateway_client_id = local.gateway_client_id
    app_roles         = local.tiers_sorted[*].app_role
  })
}

resource "azurerm_api_management_policy_fragment" "backend_mi" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-backend-managed-identity"
  format            = "xml"
  value             = file("${path.module}/policies/frag-backend-mi.xml")
}

resource "azurerm_api_management_policy_fragment" "content_safety" {
  count             = var.content_safety.enabled ? 1 : 0
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-content-safety"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-content-safety.xml", {
    cs_backend_id      = local.content_safety_backend_key != null ? azurerm_api_management_backend.svc[local.content_safety_backend_key].name : ""
    shield_prompt      = var.content_safety.shield_prompt
    category_threshold = var.content_safety.category_threshold
  })

  lifecycle {
    precondition {
      condition     = local.content_safety_backend_key != null
      error_message = "content_safety.enabled requires an ai_services entry of kind \"ContentSafety\"."
    }
  }
}

resource "azurerm_api_management_policy_fragment" "token_metric" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-token-metrics"
  format            = "xml"
  value             = file("${path.module}/policies/frag-token-metric.xml")
}

resource "azurerm_api_management_policy_fragment" "tier_rate" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-tier-rate"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-tier-rate.xml", {
    tiers   = local.tiers_sorted
    renewal = var.rate_limit_renewal_seconds
  })

  # The rendered branches read the caller-app-id variable set by the JWT fragment.
  depends_on = [azurerm_api_management_policy_fragment.entra_jwt]
}

resource "azurerm_api_management_policy_fragment" "tier_tokens" {
  api_management_id = azurerm_api_management.apim.id
  name              = "ai-tier-tokens"
  format            = "xml"
  value = templatefile("${path.module}/policies/frag-tier-tokens.xml", {
    tiers = local.tiers_sorted
  })

  depends_on = [azurerm_api_management_policy_fragment.entra_jwt]
}
