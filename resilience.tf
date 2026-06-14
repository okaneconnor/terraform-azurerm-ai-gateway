# Foundry backend member + load-balanced pool. The circuit breaker is opt-out and
# defaults to tripping on 5xx ONLY: with a single-member pool, tripping on 429
# turns one bursty client's throttling into a gateway-wide 503 for trip_duration.
# Set circuit_breaker.trip_on_429 = true when running a multi-member pool where
# failover to another region/deployment actually helps.

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

# Load-balanced pool fronting the member(s). Single member today; adding a
# second member later is one more entry in pool.services.
resource "azapi_resource" "foundry_pool" {
  type      = "Microsoft.ApiManagement/service/backends@2024-06-01-preview"
  name      = "foundry-pool"
  parent_id = azurerm_api_management.apim.id

  body = {
    properties = {
      type = "Pool"
      pool = {
        services = [{
          id       = azapi_resource.foundry_member.id
          priority = 1
          weight   = 100
        }]
      }
    }
  }

  schema_validation_enabled = false
}
