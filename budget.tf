locals {
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
