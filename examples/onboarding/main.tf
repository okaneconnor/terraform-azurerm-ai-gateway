module "onboarding" {
  #checkov:skip=CKV_TF_1:Registry source pinned by version constraint; commit hashes apply to git sources.
  source  = "okaneconnor/ai-gateway/azurerm//modules/onboarding"
  version = "~> 2.0"

  registry_file = "${path.module}/teams.yaml"

  gateway_app_object_id = var.gateway_app_object_id
  gateway_app_role_id   = var.gateway_app_role_id
  tier_names            = var.tier_names

  apim_id                    = var.apim_id
  tier_limits                = var.tier_limits
  canonical_models           = var.canonical_models
  model_map                  = var.model_map
  rate_limit_renewal_seconds = var.rate_limit_renewal_seconds
  content_safety             = var.content_safety
  defaults_file              = "${path.module}/defaults.yaml"

  limit_maxima = {
    rate_limit_calls   = 300
    tokens_per_minute  = 200000
    token_quota        = 20000000
    token_quota_period = "Monthly"
  }
}
