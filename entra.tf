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

  # The single admission role. It answers one question — is this identity an
  # approved workload permitted to reach the gateway at all — and carries no tier,
  # limits or model rights: those come from var.tiers/var.default_tier (per-team
  # via the onboarding registry). Onboarding a team therefore never changes this
  # app registration's schema.
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

# BYO mode: the app (and its service principal) already exist — resolved here so
# gateway_app_object_id / gateway_app_role_id work identically in both modes.
data "azuread_service_principal" "gateway_byo" {
  for_each  = var.existing_gateway_app != null ? { this = {} } : {}
  client_id = var.existing_gateway_app.client_id
}

locals {
  gateway_sp_object_id = var.existing_gateway_app != null ? data.azuread_service_principal.gateway_byo["this"].object_id : azuread_service_principal.gateway["this"].object_id
  # Created mode reads the role id the module itself minted (random_uuid), NOT the
  # service principal's computed app_role_ids map: that map is only refreshed when
  # the SP is read, so during an upgrade that changes the app's roles it still
  # holds the previous set and an index into it fails at plan. BYO mode has no
  # minted id, so it resolves through the SP data source (fresh every plan).
  gateway_admission_role_id = var.existing_gateway_app != null ? lookup(data.azuread_service_principal.gateway_byo["this"].app_role_ids, var.admission_app_role, null) : random_uuid.role["this"].result
}

# In BYO mode the module cannot mint the role, so its absence must fail loudly at
# plan — not surface later as a null output that breaks the consumer's onboarding
# state.
check "byo_admission_role" {
  assert {
    condition     = var.existing_gateway_app == null || local.gateway_admission_role_id != null
    error_message = "The bring-your-own gateway app defines no app role with value \"${var.admission_app_role}\" — add it to the app registration, or align var.admission_app_role with the role it does define."
  }
}

# Demo clients: one per tier preset so the per-team differentiation added by the
# onboarding registry has ready-made identities to prove limits against. Every
# demo client is admitted by the same single role.
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
  for_each = var.create_demo_clients ? var.tiers : {}
  # The minted role id, for the same upgrade-staleness reason as
  # local.gateway_admission_role_id above.
  app_role_id         = random_uuid.role["this"].result
  principal_object_id = azuread_service_principal.demo[each.key].object_id
  resource_object_id  = azuread_service_principal.gateway["this"].object_id

  # The role must exist on the gateway app before Graph will accept an
  # assignment referencing it.
  depends_on = [azuread_application.gateway]
}
