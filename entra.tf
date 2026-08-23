resource "random_uuid" "role" {
  for_each = var.existing_gateway_app == null ? var.tiers : {}
}

resource "azuread_application" "gateway" {
  for_each         = var.existing_gateway_app == null ? { this = {} } : {}
  display_name     = "${local.name_base}-gateway"
  identifier_uris  = ["api://${local.name_base}-gateway"]
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]

  api {
    requested_access_token_version = 2
  }

  dynamic "app_role" {
    for_each = var.tiers
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
  for_each  = var.existing_gateway_app == null ? { this = {} } : {}
  client_id = azuread_application.gateway["this"].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application" "demo" {
  for_each         = var.create_demo_clients ? var.tiers : {}
  display_name     = "${local.name_base}-client-${each.key}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [data.azuread_client_config.current.object_id]
}

resource "azuread_service_principal" "demo" {
  for_each  = var.create_demo_clients ? var.tiers : {}
  client_id = azuread_application.demo[each.key].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

resource "azuread_application_password" "demo" {
  for_each       = var.create_demo_clients ? var.tiers : {}
  application_id = azuread_application.demo[each.key].id
  display_name   = "client-credentials"
}

resource "azuread_app_role_assignment" "demo" {
  for_each            = var.create_demo_clients ? var.tiers : {}
  app_role_id         = azuread_service_principal.gateway["this"].app_role_ids[each.value.app_role]
  principal_object_id = azuread_service_principal.demo[each.key].object_id
  resource_object_id  = azuread_service_principal.gateway["this"].object_id
}
