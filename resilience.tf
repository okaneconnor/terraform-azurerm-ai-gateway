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

  # Serialize writes to the pool object with the destroy-time cleanup PATCH below,
  # so the two don't race on the backend's ETag during a member removal.
  locks = ["${azurerm_api_management.apim.id}/backends/foundry-pool"]

  schema_validation_enabled = false
}

# Member-removal ordering guard. Terraform destroys a removed member's backend before
# updating the pool to drop it — and Azure rejects deleting a backend still referenced
# in a pool ("...cannot be deleted"). This is a by-design Terraform core limitation
# (hashicorp/terraform#32153, #35763): when a member leaves the map, the pool's for-loop
# stops referencing it, so the dependency edge that would order "update pool before
# delete backend" simply vanishes.
#
# The fix: one destroy-time twin per member. Because this action depends_on the member
# backends, on removal Terraform destroys the twin BEFORE the member's backend — and the
# twin's PATCH detaches members from the pool, so the backend is already unreferenced
# when its DELETE runs. Terraform then updates foundry_pool (which runs last) to the
# final desired membership.
#
# The PATCH deliberately resets the pool to the PRIMARY ONLY rather than "every member
# except me". Each action's body is frozen at its last apply, so a per-member body goes
# stale the moment a sibling is also removed: destroying two twins at once made each
# re-add the other, the last writer won, and the surviving member's DELETE failed — an
# unrecoverable state, since its twin was gone too and no later apply could detach it.
# A primary-only body is identical for every member, so concurrent destroys are
# idempotent and any number of members can be removed in one apply. Ids are built as
# strings (not resource-attribute refs) to avoid a cycle back through the pool.
#
# Trade-off: between the twin's PATCH and the pool update, the pool briefly holds only
# the primary — surviving members are re-attached moments later in the same apply, and
# the primary keeps serving throughout. See docs/backend-pool.md.
resource "azapi_resource_action" "pool_member_cleanup" {
  for_each    = local.pool_members
  type        = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  resource_id = "${azurerm_api_management.apim.id}/backends/foundry-pool"
  method      = "PATCH"
  when        = "destroy"
  locks       = ["${azurerm_api_management.apim.id}/backends/foundry-pool"]

  body = {
    properties = {
      type = "Pool"
      pool = {
        services = [{
          id       = "${azurerm_api_management.apim.id}/backends/${azapi_resource.foundry_member.name}"
          priority = var.backend_pool.primary_priority
          weight   = var.backend_pool.primary_weight
        }]
      }
    }
  }

  depends_on = [azapi_resource.member_backend]
}
