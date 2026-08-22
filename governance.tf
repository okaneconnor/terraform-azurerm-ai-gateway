resource "azurerm_policy_definition" "allowed_deployment_skus" {
  for_each     = var.deployment_sku_policy.enabled ? { this = {} } : {}
  name         = "allowed-cogsvc-skus-${local.name_base}"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Allow only approved Cognitive Services model-deployment SKUs (${local.name_base})"

  policy_rule = templatefile("${path.module}/policies/deployment-sku-allowlist.json", {
    allowed_sku_names = jsonencode(var.deployment_sku_policy.allowed_sku_names)
  })
}

resource "azurerm_resource_group_policy_assignment" "allowed_deployment_skus" {
  for_each             = var.deployment_sku_policy.enabled ? { this = {} } : {}
  name                 = "allowed-deployment-skus"
  resource_group_id    = local.resource_group_id
  policy_definition_id = azurerm_policy_definition.allowed_deployment_skus["this"].id
  description          = "Data residency guardrail: model-deployment SKUs limited to ${join(", ", var.deployment_sku_policy.allowed_sku_names)}."
}
