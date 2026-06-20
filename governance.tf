# Guardrail: deny model-deployment SKUs outside the allowlist. Implemented as an
# ALLOWLIST (notIn) deliberately — Azure keeps adding non-regional SKUs
# (GlobalStandard, GlobalBatch, GlobalProvisionedManaged, DataZone*, ...) that
# process data outside the deployment region; a denylist silently fails open as
# new ones appear. The definition name is suffixed so multiple gateway instances
# in one subscription don't collide (definitions are subscription-scoped; the
# assignment is RG-scoped).

resource "azurerm_policy_definition" "allowed_deployment_skus" {
  for_each     = var.deployment_sku_policy.enabled ? { this = {} } : {}
  name         = "${var.name_prefix}-allowed-cogsvc-skus-${local.suffix}"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Allow only approved Cognitive Services model-deployment SKUs (${var.name_prefix}-${local.suffix})"

  # Policy rule lives in policies/ (like the APIM policy files) rather than inline.
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
