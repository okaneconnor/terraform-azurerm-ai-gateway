# Phase 6: Agents + self-service (azapi)
#
# Azure API Center and A2A agent APIs have NO azurerm resources, so this file
# uses the azapi provider. Each resource is gated by var.enable_agents_selfservice.
#
# The APIM Developer Portal ships with the Developer tier and needs no resource to
# "enable" — publish it via the portal "Publish" action or the APIM REST API.

# --- API Center service (stable ARM type) ---
# ARM reference: Microsoft.ApiCenter/services@2024-03-01
# https://learn.microsoft.com/azure/templates/microsoft.apicenter/services
# API Center provides the agent/API catalog. A2A agent APIs in a linked APIM
# instance synchronize automatically to API Center once the agent API exists.
# https://learn.microsoft.com/azure/api-center/agent-to-agent-overview
resource "azapi_resource" "api_center" {
  count     = var.enable_agents_selfservice ? 1 : 0
  type      = "Microsoft.ApiCenter/services@2024-03-01"
  name      = local.apic_name
  parent_id = azurerm_resource_group.rg.id
  location  = var.location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }
}

# --- A2A agent API: intentionally NOT implemented as azapi (verified, not guessed) ---
#
# DECISION: OMITTED with a documented TODO. The A2A agent API ARM/azapi shape could
# not be confirmed, so per the "honesty over completeness" constraint no resource
# body is invented here.
#
# What was verified via Microsoft Learn (2026-05-30):
#   1. "Import an A2A agent API" documents ONLY a portal flow ("APIs > + Add API >
#      A2A Agent tile"), where you supply the agent-card URL, runtime (JSON-RPC) URL,
#      agent ID, display name, and base path. There is no documented ARM template,
#      Bicep, az CLI, or azapi resource for creating an A2A agent API.
#      https://learn.microsoft.com/azure/api-management/agent-to-agent-api
#   2. The ARM reference for Microsoft.ApiManagement/service/apis — including the
#      latest preview 2024-10-01-preview — restricts `apiType` to:
#      graphql | grpc | http | odata | soap | websocket. There is NO `a2a`/agent
#      type, and no agent-card / runtime-URL / agent-ID properties on the contract.
#      ("New types can be added in the future" — i.e. not representable today.)
#      https://learn.microsoft.com/azure/templates/microsoft.apimanagement/2024-10-01-preview/service/apis
#
# Because the feature is preview and portal-only, an azapi_resource here would have
# to hallucinate the type/version and body.properties — which is explicitly
# disallowed. A `null_resource` + `local-exec` fallback was also rejected: the doc
# shows no `az apim` command for A2A agent import (only curl-based runtime testing),
# so a CLI fallback would be equally invented.
#
# TODO (manual, until an ARM/azapi shape exists):
#   With var.enable_agents_selfservice = true, after `terraform apply`:
#     a. Azure portal -> your APIM instance -> APIs -> + Add API -> "A2A Agent" tile.
#     b. Enter the agent-card URL (JSON document), then Runtime URL + Agent ID.
#     c. Set Display name and Base path; enable "Subscription required" if desired.
#   The agent API then auto-synchronizes into the linked API Center catalog above.
#   Re-evaluate this block when Microsoft publishes an ARM apiType/properties for
#   A2A (track the agent-to-agent-api doc and the Microsoft.ApiManagement ARM ref).

# --- API Center output (Task 6 Step 2; lives here, not in core-owned outputs.tf) ---
output "api_center_name" {
  description = "API Center service name (when agents + self-service is enabled)."
  value       = var.enable_agents_selfservice ? local.apic_name : null
}
