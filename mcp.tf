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
      serviceUrl           = var.existing_mcp_server_url
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
  resource_group_name = azurerm_resource_group.rg.name
  xml_content         = <<-XML
    <policies>
      <inbound>
        <base />
        <include-fragment fragment-id="ai-ip-allow" />
        <include-fragment fragment-id="ai-auth-entra-jwt" />
        <rate-limit-by-key calls="60" renewal-period="60"
          counter-key="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).AsJwt()?.Claims.GetValueOrDefault(&quot;azp&quot;,&quot;&quot;))" />
      </inbound>
      <backend><base /></backend>
      <outbound><base /></outbound>
      <on-error><base /></on-error>
    </policies>
  XML
}
