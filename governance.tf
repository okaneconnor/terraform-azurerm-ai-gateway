# Guardrail: deny model-deployment SKUs outside the allowlist. Implemented as an
# ALLOWLIST (notIn) deliberately — Azure keeps adding non-regional SKUs
# (GlobalStandard, GlobalBatch, GlobalProvisionedManaged, DataZone*, ...) that
# process data outside the deployment region; a denylist silently fails open as
# new ones appear. The definition name is suffixed so multiple gateway instances
# in one subscription don't collide (definitions are subscription-scoped; the
# assignment is RG-scoped).

resource "azurerm_policy_definition" "allowed_deployment_skus" {
  count        = var.deployment_sku_policy.enabled ? 1 : 0
  name         = "${var.name_prefix}-allowed-cogsvc-skus-${local.suffix}"
  policy_type  = "Custom"
  mode         = "All"
  display_name = "Allow only approved Cognitive Services model-deployment SKUs (${var.name_prefix}-${local.suffix})"

  # Object keys quoted ("if"/"then") so checkov's HCL parser accepts the file;
  # Terraform treats quoted and bare keys identically.
  policy_rule = jsonencode({
    "if" = {
      allOf = [
        { field = "type", equals = "Microsoft.CognitiveServices/accounts/deployments" },
        { field = "Microsoft.CognitiveServices/accounts/deployments/sku.name", notIn = var.deployment_sku_policy.allowed_sku_names },
      ]
    }
    "then" = { effect = "deny" }
  })
}

resource "azurerm_resource_group_policy_assignment" "allowed_deployment_skus" {
  count                = var.deployment_sku_policy.enabled ? 1 : 0
  name                 = "allowed-deployment-skus"
  resource_group_id    = local.resource_group_id
  policy_definition_id = azurerm_policy_definition.allowed_deployment_skus[0].id
  description          = "Data residency guardrail: model-deployment SKUs limited to ${join(", ", var.deployment_sku_policy.allowed_sku_names)}."
}
