# PREVIEW (off by default; var.enable_mcp). APIM MCP server support is preview and
# this azapi passthrough import is not yet a reliably-routing MCP endpoint via ARM —
# verified to deploy an API shell that returns 404 on the MCP paths. Kept as the
# MS-documented codified shape; the reliable path today is the portal
# (APIs -> MCP servers -> Create MCP server). Once functional, the API Center
# apiSource integration catalogues it automatically.
resource "azapi_resource" "existing_mcp" {
  count     = var.enable_mcp ? 1 : 0
  type      = "Microsoft.ApiManagement/service/apis@2025-09-01-preview"
  name      = "governed-mcp"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      displayName          = "Governed external MCP server"
      path                 = "mytools"
      apiType              = "mcp"
      protocols            = ["https"]
      serviceUrl           = var.mcp_server_url
      subscriptionRequired = false
      mcpProperties        = { transportType = "streamable" }
    }
  }
  schema_validation_enabled = false
}

resource "azurerm_api_management_api_policy" "mcp" {
  count               = var.enable_mcp ? 1 : 0
  api_name            = azapi_resource.existing_mcp[0].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = local.resource_group_name
  xml_content         = <<-XML
    <policies>
      <inbound>
        <base />
        <include-fragment fragment-id="ai-ip-allow" />
        <include-fragment fragment-id="ai-auth-entra-jwt" />
        <rate-limit-by-key calls="${var.mcp_rate_limit_calls}" renewal-period="${var.rate_limit_renewal_seconds}"
          counter-key="@((string)context.Variables[&quot;caller-app-id&quot;])" />
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML

  depends_on = [
    azurerm_api_management_policy_fragment.ip_allow,
    azurerm_api_management_policy_fragment.entra_jwt,
  ]
}
