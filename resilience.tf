resource "azapi_resource" "foundry_member" {
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "foundry-openai-member"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = merge(
      {
        type     = "Single"
        protocol = "http"
        url      = "${azurerm_cognitive_account.foundry.endpoint}openai"
      },
      var.circuit_breaker.enabled ? {
        circuitBreaker = {
          rules = [{
            name = "foundryBreaker"
            failureCondition = {
              count    = var.circuit_breaker.failure_count
              interval = var.circuit_breaker.interval
              statusCodeRanges = concat(
                var.circuit_breaker.trip_on_429 ? [{ min = 429, max = 429 }] : [],
                [{ min = 500, max = 599 }],
              )
            }
            tripDuration     = var.circuit_breaker.trip_duration
            acceptRetryAfter = var.circuit_breaker.accept_retry_after
          }]
        }
      } : {}
    )
  }

  schema_validation_enabled = false
}

# One Single backend per additional pool member (module-created or BYO), each with
# its own circuit breaker (per-member override merged over var.circuit_breaker).
resource "azapi_resource" "member_backend" {
  for_each  = local.pool_members
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "foundry-member-${each.key}"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = merge(
      {
        type     = "Single"
        protocol = "http"
        url      = local.member_endpoint[each.key]
      },
      local.member_cb[each.key].enabled ? {
        circuitBreaker = {
          rules = [{
            name = "${each.key}Breaker"
            failureCondition = {
              count    = local.member_cb[each.key].failure_count
              interval = local.member_cb[each.key].interval
              statusCodeRanges = concat(
                local.member_cb[each.key].trip_on_429 ? [{ min = 429, max = 429 }] : [],
                [{ min = 500, max = 599 }],
              )
            }
            tripDuration     = local.member_cb[each.key].trip_duration
            acceptRetryAfter = local.member_cb[each.key].accept_retry_after
          }]
        }
      } : {}
    )
  }

  schema_validation_enabled = false
}

# Load-balanced pool fronting the member(s): the primary (module's own Foundry
# account) plus any additional pool members, each with its own priority/weight.
resource "azapi_resource" "foundry_pool" {
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "foundry-pool"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      type = "Pool"
      pool = {
        services = concat(
          [{
            id       = azapi_resource.foundry_member.id
            priority = var.backend_pool.primary_priority
            weight   = var.backend_pool.primary_weight
          }],
          [for k, m in local.pool_members : {
            id       = azapi_resource.member_backend[k].id
            priority = m.priority
            weight   = m.weight
          }],
        )
      }
    }
  }

  schema_validation_enabled = false
}
