# Opt-in resource-group consumption budget (var.budget, default off). Azure OpenAI has
# no hard spend cap and the per-tier token quotas only bound each consumer, not the
# total — this bounds total RG spend and notifies on actual + forecasted overspend.
# Notifications go to var.budget.contact_emails and, when alerting is enabled (or an
# action group is supplied), to that action group too.

locals {
  # The budget's own action group (if supplied) plus the var.alerts action group.
  budget_action_groups = distinct(compact(concat(
    var.budget.action_group_id != null ? [var.budget.action_group_id] : [],
    local.action_group_ids,
  )))
}

resource "azurerm_consumption_budget_resource_group" "budget" {
  for_each          = var.budget.enabled ? { this = {} } : {}
  name              = "${var.name_prefix}-budget-${local.suffix}"
  resource_group_id = local.resource_group_id
  amount            = var.budget.amount
  time_grain        = var.budget.time_grain

  time_period {
    start_date = var.budget.start_date
  }

  dynamic "notification" {
    for_each = { for n in var.budget.notifications : "${n.type}-${n.threshold}" => n }
    content {
      enabled        = true
      threshold      = notification.value.threshold
      threshold_type = notification.value.type
      operator       = "GreaterThanOrEqualTo"
      contact_emails = var.budget.contact_emails
      contact_groups = local.budget_action_groups
    }
  }
}
