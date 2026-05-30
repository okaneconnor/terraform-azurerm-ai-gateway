resource "random_uuid" "role" {
  for_each = var.products
}

resource "azuread_application" "gateway" {
  display_name     = "${var.name_prefix}-gateway-${local.suffix}"
  identifier_uris  = ["api://${var.name_prefix}-gateway-${local.suffix}"]
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  api {
    requested_access_token_version = 2
  }

  dynamic "app_role" {
    for_each = var.products
    content {
      allowed_member_types = ["Application"]
      description          = "Access the ${app_role.value.display_name} tier"
      display_name         = app_role.value.display_name
      enabled              = true
      id                   = random_uuid.role[app_role.key].result
      value                = app_role.value.app_role
    }
  }
}

resource "azuread_service_principal" "gateway" {
  client_id = azuread_application.gateway.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

# Demo client application (one per tier could be created; here one client granted sandbox)
resource "azuread_application" "client" {
  display_name     = "${var.name_prefix}-client-${local.suffix}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "client" {
  client_id = azuread_application.client.client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "client" {
  application_id = azuread_application.client.id
  display_name   = "client-credentials"
}

resource "azuread_app_role_assignment" "client_sandbox" {
  app_role_id         = azuread_service_principal.gateway.app_role_ids["AI.Gateway.Sandbox"]
  principal_object_id = azuread_service_principal.client.object_id
  resource_object_id  = azuread_service_principal.gateway.object_id
}
