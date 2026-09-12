resource "random_uuid" "role" {
  for_each = var.existing_gateway_app == null ? { this = {} } : {}
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

  # Single admission role: grants entry only — tier/limits come from config.
  app_role {
    allowed_member_types = ["Application"]
    description          = "Admitted to call the AI gateway. Consumption limits are configured per caller, not carried by this role."
    display_name         = "AI Gateway Access"
    enabled              = true
    id                   = random_uuid.role["this"].result
    value                = var.admission_app_role
  }
}

resource "azuread_service_principal" "gateway" {
  for_each  = var.existing_gateway_app == null ? { this = {} } : {}
  client_id = azuread_application.gateway["this"].client_id
  owners    = [data.azuread_client_config.current.object_id]
}

data "azuread_service_principal" "gateway_byo" {
  for_each  = var.existing_gateway_app != null ? { this = {} } : {}
  client_id = var.existing_gateway_app.client_id
}

check "byo_admission_role" {
  assert {
    # Ternary, not ||: 1.9.x evaluates `true || unknown` as unknown.
    condition     = var.existing_gateway_app == null ? true : local.gateway_admission_role_id != null
    error_message = "The bring-your-own gateway app defines no app role with value \"${var.admission_app_role}\" — add it to the app registration, or align var.admission_app_role with the role it does define."
  }
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
  app_role_id         = random_uuid.role["this"].result
  principal_object_id = azuread_service_principal.demo[each.key].object_id
  resource_object_id  = azuread_service_principal.gateway["this"].object_id

  depends_on = [azuread_application.gateway]
}
