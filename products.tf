# Products intentionally omitted (keyless model).
#
# APIM rule: an API can belong to at most ONE *open* product (a product with
# subscription_required = false). Our gateway is keyless (Entra JWT, no
# subscription keys), so two open tier-products (ai-sandbox / ai-production-standard)
# both containing every API is impossible — APIM returns:
#   "API cannot be added to more than one open product."
# Product policies also do NOT execute for keyless requests (there is no
# subscription -> product context at runtime).
#
# Therefore access is gated entirely by the API-level `ai-auth-entra-jwt` fragment
# (validates the token + an AI.Gateway.* role), and per-tier throttling belongs in
# the API policies keyed by the JWT app-role (AI.Gateway.Sandbox /
# AI.Gateway.Production). See the README "Tiering" note and the follow-up to add a
# role-based throttle fragment to the API policies.
#
# var.products is retained: it drives the Entra app roles in entra.tf.
