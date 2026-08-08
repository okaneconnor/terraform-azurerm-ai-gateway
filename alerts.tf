# Opt-in alerting (var.alerts, default off). Creates an action group (or reuses one
# the caller passes) and a set of metric + log-query alerts covering the failure modes
# we actually hit: capacity pressure, gateway 5xx, sustained throttling (429), backend
# connection failures, and a model deployment approaching its token-per-minute quota.

locals {
  create_action_group = var.alerts.enabled && var.alerts.existing_action_group_id == null
  action_group_id = var.alerts.existing_action_group_id != null ? var.alerts.existing_action_group_id : (
    var.alerts.enabled ? azurerm_monitor_action_group.main["this"].id : null
  )
  # For alert `action`/`action_groups` blocks — empty list when there's no group.
  action_group_ids = local.action_group_id != null ? [local.action_group_id] : []
}

resource "azurerm_monitor_action_group" "main" {
  for_each            = local.create_action_group ? { this = {} } : {}
  name                = "${var.name_prefix}-alerts-${local.suffix}"
  resource_group_name = local.resource_group_name
  short_name          = "aigwalerts"
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = { for i, e in var.alerts.email_receivers : tostring(i) => e }
    content {
      name          = "email-${email_receiver.key}"
      email_address = email_receiver.value
    }
  }
}

# APIM capacity (percent) above threshold — the gateway is running hot.
resource "azurerm_monitor_metric_alert" "apim_capacity" {
  for_each            = var.alerts.enabled ? { this = {} } : {}
  name                = "${var.name_prefix}-apim-capacity-${local.suffix}"
  resource_group_name = local.resource_group_name
  scopes              = [azurerm_api_management.apim.id]
  description         = "APIM capacity above ${var.alerts.apim_capacity_threshold}%."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Capacity"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.alerts.apim_capacity_threshold
  }

  action {
    action_group_id = local.action_group_id
  }
}

# Gateway 5xx responses over the window (5xx is unambiguous — unlike 4xx, which is
# dominated by the normal 401s this keyless gateway returns to unauthenticated probes).
resource "azurerm_monitor_metric_alert" "gateway_5xx" {
  for_each            = var.alerts.enabled ? { this = {} } : {}
  name                = "${var.name_prefix}-gateway-5xx-${local.suffix}"
  resource_group_name = local.resource_group_name
  scopes              = [azurerm_api_management.apim.id]
  description         = "More than ${var.alerts.gateway_5xx_threshold} gateway 5xx responses in 5 minutes."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.alerts.gateway_5xx_threshold

    dimension {
      name     = "GatewayResponseCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = local.action_group_id
  }
}

# A model deployment approaching its TPM quota — only when the caller sets a threshold
# (tokens/minute) near their deployment's limit.
resource "azurerm_monitor_metric_alert" "model_tokens" {
  for_each            = var.alerts.enabled && var.alerts.model_tokens_per_min_threshold != null ? { this = {} } : {}
  name                = "${var.name_prefix}-model-tokens-${local.suffix}"
  resource_group_name = local.resource_group_name
  scopes              = [azurerm_cognitive_account.foundry.id]
  description         = "Foundry token throughput above ${var.alerts.model_tokens_per_min_threshold}/min (approaching quota)."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT1M"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "TokenTransaction"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.alerts.model_tokens_per_min_threshold
  }

  action {
    action_group_id = local.action_group_id
  }
}

# Sustained throttling (429) — precise via the log table, since 429 can't be isolated
# from the 4xx metric dimension.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "throttle_429" {
  for_each             = var.alerts.enabled ? { this = {} } : {}
  name                 = "${var.name_prefix}-throttle-429-${local.suffix}"
  resource_group_name  = local.resource_group_name
  location             = local.resource_group_location
  description          = "More than ${var.alerts.throttle_429_threshold} throttled (429) requests in 5 minutes."
  severity             = 3
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [local.log_analytics_workspace_id]
  tags                 = var.tags

  criteria {
    query                   = "ApiManagementGatewayLogs | where ResponseCode == 429"
    time_aggregation_method = "Count"
    threshold               = var.alerts.throttle_429_threshold
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = local.action_group_ids
  }
}

# Backend connection failures — the real BackendConnectionFailure we saw under burst.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "backend_failures" {
  for_each             = var.alerts.enabled ? { this = {} } : {}
  name                 = "${var.name_prefix}-backend-failures-${local.suffix}"
  resource_group_name  = local.resource_group_name
  location             = local.resource_group_location
  description          = "More than ${var.alerts.backend_failure_threshold} backend connection failures in 5 minutes."
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT5M"
  scopes               = [local.log_analytics_workspace_id]
  tags                 = var.tags

  criteria {
    query                   = "ApiManagementGatewayLogs | where LastErrorReason has \"Backend\""
    time_aggregation_method = "Count"
    threshold               = var.alerts.backend_failure_threshold
    operator                = "GreaterThan"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = local.action_group_ids
  }
}
