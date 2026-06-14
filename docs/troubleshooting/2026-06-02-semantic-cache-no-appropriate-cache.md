# Troubleshooting note — Semantic cache silently did nothing ("No appropriate cache found")

**Date:** 2026-06-02
**Component:** APIM AI Gateway → semantic caching (`llm-semantic-cache-lookup` / `-store`) on the Foundry API
**Status:** RESOLVED

---

## Symptom

Semantic caching appeared completely inert:
- Identical prompts always returned a **new** completion `id` (no cache hit).
- Azure Managed Redis metrics showed **0 gets, 0 sets, 0 connected clients** — ever.
- Every other gateway capability worked (auth, tiering, content safety, passthrough).

## What it was NOT (the false trails we chased)

All of these were investigated and verified **correct** — none of them were the cause:

| Suspected cause | Verified | Result |
|---|---|---|
| NSG blocking port 10000 | inbound + outbound rules dumped | default `AllowVnet*` covers 10000; no deny |
| Private DNS misconfig | dig/zone records | public CNAME → `privatelink` → private IP `10.90.2.12` ✓ |
| APIM not in the cache's VNet | subnet check | APIM + Redis PE in the same VNet ✓ |
| Stale APIM DNS cache | ran `applynetworkconfigurationupdates` | no change |
| Policy ordering (content-safety consuming the body) | reordered lookup earlier | no change |
| Connection string / port / RediSearch / clustering policy | provider state + MS docs | all correct (`EnterpriseCluster` is required for RediSearch) |
| Embeddings failing | called embeddings via gateway | returns 200 with a vector |
| Private-endpoint unreachable | enabled Redis public access (via 2025-07-01 API) | **still inert** |

The misleading signal was **"0 Redis ops / 0 connected clients,"** which screams "connectivity" — so we spent most of the effort on the network layer, which was never the problem.

## How we actually found it — the APIM request trace

Standard telemetry does **not** surface a semantic-cache hit/miss or the policy's internal embeddings/Redis sub-calls:
- App Insights `AppDependencies` showed the content-safety + chat backend calls but **no embeddings/Redis call** — proving the lookup bailed *before* those steps.
- The resource-log table `ApiManagementGatewayLogs` never ingested (and wouldn't show cache internals anyway).

The decisive tool was the **APIM request trace** (API Inspector):

1. Enable tracing on the built-in `master` subscription (reversible):
   ```bash
   az rest --method PATCH \
     --url ".../service/<apim>/subscriptions/master?api-version=2024-05-01" \
     --headers "Content-Type=application/json" \
     --body '{"properties":{"allowTracing":true}}'
   ```
2. Fire a request with the trace headers, using the master key:
   ```bash
   curl ... -H "Ocp-Apim-Subscription-Key: <master-primaryKey>" -H "Ocp-Apim-Trace: true"
   ```
3. Read the `Ocp-Apim-Trace-Location` URL (a SAS link to the trace JSON) and inspect `traceEntries.inbound` for the `azure-openai-semantic-cache-lookup` entry.
4. **Disable tracing again** afterwards (`allowTracing:false`).

The trace gave the exact, otherwise-invisible message:

```
source: azure-openai-semantic-cache-lookup
data:   "No appropriate cache found for provided policy configuration.
         Policy execution will be skipped."

source: cache-store
data:   "Corresponding azure-openai-semantic-cache-lookup policy was not applied.
         Skipping azure-openai-semantic-cache-store."
```

## Root cause

The external Redis cache was registered with **`Use from = "default"`** (`useFromLocation: "default"`).
The semantic-cache policy could not **match** a cache to this single-region gateway, so it **skipped itself entirely** — which is why it never computed an embedding or issued a single Redis command. It was a **cache-to-gateway binding** problem, not connectivity.

## The fix

Bind the external cache to the gateway's **specific region** instead of `"default"`:

```hcl
# redis.tf  →  azurerm_api_management_redis_cache.cache
cache_location = "UK South"   # must match the gateway location APIM reports; was implicitly "default"
```

APIM normalises this to `useFromLocation: "uksouth"` and the gateway then matches it. After applying, identical prompts return the **same completion id in ~0.2s** (vs ~1.4s for a real backend call) — confirmed cache hits.

## Lessons / runbook for "AI gateway cache not working"

1. **Get the APIM request trace FIRST.** Semantic-cache hit/miss and the policy's internal sub-calls are invisible to GatewayLogs, App Insights, and Redis metrics. Only the trace shows the policy's own decision (`"No appropriate cache found…"`, miss, hit, etc.).
2. **`0 Redis ops` does not imply a connectivity fault** — the policy can decide there's no cache and never connect.
3. **Register the external cache to the gateway's region, not `"default"`,** for single-region instances.
4. Semantic caching uses RediSearch **vector** commands (`FT.*`), so Redis `getcommands`/`setcommands` metrics stay at 0 even when the cache works — don't use those as the hit/miss signal; use response `id` equality / latency.
5. Side note discovered en route: `azurerm_managed_redis.public_network_access` is a **no-op** on the current provider (the `publicNetworkAccess` property needs the `Microsoft.Cache/redisEnterprise` **2025-07-01** API; toggle it via `azapi`/`az rest` if ever needed).
