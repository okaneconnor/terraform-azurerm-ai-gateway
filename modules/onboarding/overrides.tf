# The overrides seam: renders per-team policy (limits, model allowlist,
# content safety) from the merged registry and writes it into the gateway's
# onboarding-owned policy fragments via azapi. Merge semantics, most specific
# wins: service > team > defaults file > tier preset / platform settings.
# Maps deep-merge per key; lists (allowed_models) replace wholesale.

locals {
  overrides_enabled = var.apim_id != null

  defaults_raw = var.defaults_file == null ? null : yamldecode(file(var.defaults_file))
  defaults = {
    allowed_models = try(local.defaults_raw.allowed_models, null)
    content_safety = try(local.defaults_raw.content_safety, null)
  }
  defaults_unknown = var.defaults_file == null ? [] : try(setsubtract(keys(local.defaults_raw), ["allowed_models", "content_safety"]), tolist(["<defaults file is not a YAML mapping>"]))

  override_bearers = concat(
    [for t in local.teams : { where = "team ${coalesce(t.team, "?")}", limits = t.limits, models = t.allowed_models, cs = t.content_safety }],
    [for s in local.services : { where = s.key, limits = s.limits, models = s.allowed_models, cs = s.content_safety }],
  )
  any_overrides = var.defaults_file != null || anytrue([
    for b in local.override_bearers : b.limits != null || b.models != null || b.cs != null
  ])

  limits_allowed_keys = ["rate_limit_calls", "tokens_per_minute", "token_quota", "token_quota_period"]
  quota_periods       = ["Hourly", "Daily", "Weekly", "Monthly", "Yearly"]
  limit_entries       = [for b in local.override_bearers : { where = b.where, limits = b.limits } if b.limits != null]

  limit_unknown = [for e in local.limit_entries : {
    where = e.where
    bad   = try(setsubtract(keys(e.limits), local.limits_allowed_keys), tolist(["<limits is not a mapping>"]))
  }]
  limit_bad_values = [for e in local.limit_entries : e.where if length([
    for k in ["rate_limit_calls", "tokens_per_minute", "token_quota"] : k
    if contains(try(keys(e.limits), []), k) && !try(e.limits[k] > 0 && floor(e.limits[k]) == e.limits[k], false)
  ]) > 0]
  limit_bad_period = [for e in local.limit_entries : e.where
  if contains(try(keys(e.limits), []), "token_quota_period") && !try(contains(local.quota_periods, e.limits.token_quota_period), false)]

  model_lists = concat(
    local.defaults.allowed_models != null ? [{ where = "defaults", models = local.defaults.allowed_models }] : [],
    [for b in local.override_bearers : { where = b.where, models = b.models } if b.models != null],
  )
  model_empty = [for e in local.model_lists : e.where if try(length(e.models), 0) == 0]
  model_unknown = var.canonical_models == null ? [] : [for e in local.model_lists : {
    where = e.where
    bad   = try([for m in e.models : m if !contains(var.canonical_models, m)], tolist(["<allowed_models is not a list>"]))
  }]

  cs_allowed_keys = ["enabled", "categories"]
  cs_cat_keys     = ["hate", "self_harm", "sexual", "violence"]
  cs_cat_allowed  = ["enabled", "threshold"]
  cs_names        = { hate = "Hate", self_harm = "SelfHarm", sexual = "Sexual", violence = "Violence" }

  cs_entries = concat(
    local.defaults.content_safety != null ? [{ where = "defaults", cs = local.defaults.content_safety }] : [],
    [for b in local.override_bearers : { where = b.where, cs = b.cs } if b.cs != null],
  )
  cs_unknown = [for e in local.cs_entries : {
    where = e.where
    bad = distinct(concat(
      try(tolist(setsubtract(keys(e.cs), local.cs_allowed_keys)), tolist(["<content_safety is not a mapping>"])),
      try(tolist(setsubtract(keys(e.cs.categories), local.cs_cat_keys)),
      contains(try(keys(e.cs), []), "categories") ? tolist(["<categories is not a mapping>"]) : []),
      # Per category, not one try around the lot: a single scalar category would
      # otherwise swallow the whole entry's unknown-key detection.
      flatten([for c in local.cs_cat_keys :
        try(tolist(setsubtract(keys(e.cs.categories[c]), local.cs_cat_allowed)), [])
      if contains(try(keys(try(e.cs.categories, {})), []), c)]),
    ))
  }]

  # `violence: 2` is the natural shorthand for `violence: { threshold: 2 }` and
  # would otherwise be accepted and silently ignored (team gets the default).
  cs_scalar_categories = [for e in local.cs_entries : e.where if !alltrue([
    for c in local.cs_cat_keys :
    !contains(try(keys(try(e.cs.categories, {})), []), c) || can(keys(e.cs.categories[c]))
  ])]
  cs_bad_threshold = [for e in local.cs_entries : e.where if !alltrue([
    for c in local.cs_cat_keys :
    !contains(try(keys(try(e.cs.categories, {})), []), c) || !contains(try(keys(e.cs.categories[c]), []), "threshold") || try(e.cs.categories[c].threshold >= 0 && e.cs.categories[c].threshold <= 7 && floor(e.cs.categories[c].threshold) == e.cs.categories[c].threshold, false)
  ])]
  cs_bad_enabled = [for e in local.cs_entries : e.where if !alltrue(concat(
    [!contains(try(keys(e.cs), []), "enabled") || try(e.cs.enabled == true || e.cs.enabled == false, false)],
    [for c in local.cs_cat_keys :
    !contains(try(keys(try(e.cs.categories, {})), []), c) || !contains(try(keys(e.cs.categories[c]), []), "enabled") || try(e.cs.categories[c].enabled == true || e.cs.categories[c].enabled == false, false)]
  ))]
  # Disabling every category screens nothing but shield — the same escape the
  # top-level flag is gated on, so both spellings answer to the same switch.
  cs_optout = [for e in local.cs_entries : e.where if anytrue(concat(
    [try(e.cs.enabled == false, false)],
    [for c in local.cs_cat_keys : try(e.cs.categories[c].enabled == false, false)],
  ))]
  needs_cs_contract = local.overrides_enabled && length(local.cs_entries) > 0 && var.content_safety == null

  tiers_missing = local.overrides_enabled && var.tier_limits != null ? distinct([
    for t in local.teams : t.tier if t.tier != null && !contains(keys(var.tier_limits), t.tier)
  ]) : []

  # Effective (merged) config per service. try-total: malformed input must
  # surface through the guard's named rules, never a raw evaluation error —
  # including duplicate keys (grouped here; the registry_guard names them).
  effective = { for k, v in local.effective_grouped : k => v[0] }

  effective_grouped = { for s in local.services : s.key => {
    team      = s.team
    service   = s.service
    tier      = s.tier
    client_id = s.client_id
    limits = {
      rate_limit_calls   = try(coalesce(try(s.limits.rate_limit_calls, null), try(s.team_limits.rate_limit_calls, null), try(var.tier_limits[s.tier].rate_limit_calls, null)), null)
      tokens_per_minute  = try(coalesce(try(s.limits.tokens_per_minute, null), try(s.team_limits.tokens_per_minute, null), try(var.tier_limits[s.tier].tokens_per_minute, null)), null)
      token_quota        = try(coalesce(try(s.limits.token_quota, null), try(s.team_limits.token_quota, null), try(var.tier_limits[s.tier].token_quota, null)), null)
      token_quota_period = try(coalesce(try(s.limits.token_quota_period, null), try(s.team_limits.token_quota_period, null), try(var.tier_limits[s.tier].token_quota_period, null)), "Monthly")
    }
    allowlist_explicit = s.allowed_models != null || s.team_models != null || local.defaults.allowed_models != null
    allowed_models     = try(sort(s.allowed_models != null ? s.allowed_models : (s.team_models != null ? s.team_models : (local.defaults.allowed_models != null ? local.defaults.allowed_models : coalesce(var.canonical_models, [])))), tolist([]))
    cs = {
      overridden = s.content_safety != null || s.team_cs != null || local.defaults.content_safety != null
      enabled    = try(tobool(coalesce(try(s.content_safety.enabled, null), try(s.team_cs.enabled, null), try(local.defaults.content_safety.enabled, null), true)), true)
      categories = [for c in local.cs_cat_keys : {
        name      = local.cs_names[c]
        enabled   = try(coalesce(try(s.content_safety.categories[c].enabled, null), try(s.team_cs.categories[c].enabled, null), try(local.defaults.content_safety.categories[c].enabled, null), true), true)
        threshold = try(coalesce(try(s.content_safety.categories[c].threshold, null), try(s.team_cs.categories[c].threshold, null), try(local.defaults.content_safety.categories[c].threshold, null), try(var.content_safety.category_threshold, null), 4), 4)
      }]
    }
  }... }

  unresolved = [for k, e in local.effective : k if e.limits.rate_limit_calls == null || e.limits.tokens_per_minute == null]

  # Quota ceilings are meaningless without the period: Hourly vs Monthly is a
  # ~730x difference on the same number. Both sides normalise to tokens/day.
  period_days = { Hourly = 1 / 24, Daily = 1, Weekly = 7, Monthly = 30, Yearly = 365 }
  maxima_daily_quota = try(var.limit_maxima.token_quota, null) == null ? null : (
    var.limit_maxima.token_quota / lookup(local.period_days, coalesce(try(var.limit_maxima.token_quota_period, null), "Monthly"), 30)
  )

  any_explicit_allowlist = anytrue([for k, e in local.effective : e.allowlist_explicit])

  over_maxima = var.limit_maxima == null ? [] : [for k, e in local.effective : k if anytrue([
    var.limit_maxima.rate_limit_calls != null && try(e.limits.rate_limit_calls > var.limit_maxima.rate_limit_calls, false),
    var.limit_maxima.tokens_per_minute != null && try(e.limits.tokens_per_minute > var.limit_maxima.tokens_per_minute, false),
    local.maxima_daily_quota != null && try(e.limits.token_quota / local.period_days[e.limits.token_quota_period] > local.maxima_daily_quota, false),
  ])]

  # Sorted list + sentinel zeros keep the render total and diff-stable; the
  # guard rejects any registry that could actually reach a sentinel.
  render_services = [for k in sort(keys(local.effective)) : merge(local.effective[k], {
    allowed_deployments = distinct(sort([
      for m in local.effective[k].allowed_models : lookup(coalesce(var.model_map, {}), m, m)
    ]))
    limits = {
      rate_limit_calls   = coalesce(local.effective[k].limits.rate_limit_calls, 0)
      tokens_per_minute  = coalesce(local.effective[k].limits.tokens_per_minute, 0)
      token_quota        = local.effective[k].limits.token_quota
      token_quota_period = local.effective[k].limits.token_quota_period
    }
    cs_enabled_categories = [for c in local.effective[k].cs.categories : c if try(c.enabled, true) == true]
  })]
  cs_render = [for s in local.render_services : s if s.cs.overridden]

  team_overrides_xml = templatefile("${path.module}/templates/team-overrides.xml.tftpl", {
    services = local.render_services
    renewal  = var.rate_limit_renewal_seconds
  })
  team_cs_xml = length(local.cs_render) > 0 && var.content_safety != null ? templatefile("${path.module}/templates/team-cs.xml.tftpl", {
    services = local.cs_render
    backend  = var.content_safety.backend_name
    shield   = var.content_safety.shield_prompt
    enforce  = var.content_safety.enforce_on_completions
  }) : file("${path.module}/policies/frag-team-cs-inert.xml")
}

resource "terraform_data" "overrides_guard" {
  lifecycle {
    precondition {
      condition     = length(local.defaults_unknown) == 0
      error_message = "Unknown key(s) in the defaults file: ${join(", ", local.defaults_unknown)}. Allowed: allowed_models, content_safety."
    }
    precondition {
      condition     = local.overrides_enabled || !local.any_overrides
      error_message = "The registry or defaults file declares overrides (limits / allowed_models / content_safety) but apim_id is not set — they would silently do nothing. Pass the gateway module's apim_id output (plus tier_limits and canonical_models) to activate the overrides seam."
    }
    precondition {
      condition     = !local.overrides_enabled || (var.tier_limits != null && var.canonical_models != null)
      error_message = "apim_id is set but ${join(" and ", compact([var.tier_limits == null ? "tier_limits" : "", var.canonical_models == null ? "canonical_models" : ""]))} missing — pass the gateway module's tiers and canonical_models outputs."
    }
    precondition {
      condition     = alltrue([for u in local.limit_unknown : length(u.bad) == 0])
      error_message = "Unknown key(s) in limits: ${join("; ", [for u in local.limit_unknown : "${u.where}: ${join(", ", u.bad)}" if length(u.bad) > 0])}. Allowed: ${join(", ", local.limits_allowed_keys)}."
    }
    precondition {
      condition     = length(local.limit_bad_values) == 0
      error_message = "Limit values must be positive integers (rate_limit_calls, tokens_per_minute, token_quota): ${join(", ", local.limit_bad_values)}."
    }
    precondition {
      condition     = length(local.limit_bad_period) == 0
      error_message = "token_quota_period must be one of ${join(", ", local.quota_periods)}: ${join(", ", local.limit_bad_period)}."
    }
    precondition {
      condition     = length(local.model_empty) == 0
      error_message = "allowed_models must be a non-empty list (an empty list would block every model): ${join(", ", local.model_empty)}."
    }
    precondition {
      condition     = alltrue([for u in local.model_unknown : length(u.bad) == 0])
      error_message = "allowed_models name(s) the gateway does not serve: ${join("; ", [for u in local.model_unknown : "${u.where}: ${join(", ", u.bad)}" if length(u.bad) > 0])}. Canonical models: ${join(", ", coalesce(var.canonical_models, []))}."
    }
    precondition {
      condition     = alltrue([for u in local.cs_unknown : length(u.bad) == 0])
      error_message = "Unknown key(s) in content_safety: ${join("; ", [for u in local.cs_unknown : "${u.where}: ${join(", ", u.bad)}" if length(u.bad) > 0])}. Allowed: enabled, categories.{${join(",", local.cs_cat_keys)}}.{enabled, threshold}."
    }
    precondition {
      condition     = length(local.cs_scalar_categories) == 0
      error_message = "content_safety categories must be mappings, not bare values: ${join(", ", local.cs_scalar_categories)}. Write `violence: { threshold: 2 }`, not `violence: 2` — the shorthand would be accepted and silently ignored, leaving the platform default in force."
    }
    precondition {
      condition     = length(local.cs_bad_threshold) == 0
      error_message = "content_safety thresholds must be integers 0-7 (EightSeverityLevels; blocks at >= threshold): ${join(", ", local.cs_bad_threshold)}."
    }
    precondition {
      condition     = length(local.cs_bad_enabled) == 0
      error_message = "content_safety enabled flags must be booleans: ${join(", ", local.cs_bad_enabled)}."
    }
    precondition {
      condition     = var.allow_team_content_safety_opt_out || length(local.cs_optout) == 0
      error_message = "content_safety.enabled = false found (${join(", ", local.cs_optout)}) but the platform does not allow opt-out. Screening is a platform guarantee; set allow_team_content_safety_opt_out = true only if you accept unscreened callers."
    }
    precondition {
      condition     = !local.needs_cs_contract
      error_message = "content_safety overrides are declared but the content_safety input is not set — pass the gateway module's content_safety_contract output (null means the gateway runs without content safety, so there is nothing to override)."
    }
    precondition {
      condition     = length(local.tiers_missing) == 0
      error_message = "tier_limits has no entry for tier(s): ${join(", ", local.tiers_missing)}. Pass the gateway module's tiers output unmodified."
    }
    precondition {
      condition     = !local.overrides_enabled || length(local.unresolved) == 0
      error_message = "Could not resolve effective limits for: ${join(", ", local.unresolved)}. Every service needs rate_limit_calls and tokens_per_minute from its overrides or its team's tier preset."
    }
    precondition {
      condition     = !local.overrides_enabled || !local.any_explicit_allowlist || var.model_map != null
      error_message = "allowed_models is declared but model_map is not set — pass the gateway module's model_map output. Without it the allowlist cannot be enforced on the legacy /openai surface, which addresses deployments rather than canonical names, and a caller could use it to reach a model its allowlist excludes."
    }
    precondition {
      condition     = length(local.over_maxima) == 0
      error_message = "Effective limits exceed the platform maxima (limit_maxima): ${join(", ", local.over_maxima)}."
    }
  }
}

# Writers are fire-and-forget PUT actions, not tracked resources: APIM
# re-serialises stored fragment XML (tab indentation), so a tracked body would
# perpetually diff against the normalised read-back. The rev hash forces a
# re-fire whenever the rendered content changes.
resource "terraform_data" "team_overrides_rev" {
  for_each = local.overrides_enabled ? { this = {} } : {}
  input    = sha256(local.team_overrides_xml)
}

resource "azapi_resource_action" "team_overrides_write" {
  for_each    = local.overrides_enabled ? { this = {} } : {}
  type        = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  resource_id = "${var.apim_id}/policyFragments/ai-team-overrides"
  method      = "PUT"

  body = {
    properties = {
      format = "xml"
      value  = local.team_overrides_xml
    }
  }

  locks = ["${var.apim_id}/policyFragments/ai-team-overrides"]

  lifecycle {
    replace_triggered_by = [terraform_data.team_overrides_rev["this"]]
  }

  depends_on = [terraform_data.registry_guard, terraform_data.overrides_guard]
}

# Destroy-time twin: the writer cannot restore what it overwrote,
# so removal resets the fragment to the gateway's inert content.
resource "azapi_resource_action" "team_overrides_reset" {
  for_each    = local.overrides_enabled ? { this = {} } : {}
  type        = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  resource_id = "${var.apim_id}/policyFragments/ai-team-overrides"
  method      = "PUT"
  when        = "destroy"

  body = {
    properties = {
      format = "xml"
      value  = file("${path.module}/policies/frag-team-overrides-inert.xml")
    }
  }

  locks = ["${var.apim_id}/policyFragments/ai-team-overrides"]
}

resource "terraform_data" "team_content_safety_rev" {
  for_each = local.overrides_enabled ? { this = {} } : {}
  input    = sha256(local.team_cs_xml)
}

resource "azapi_resource_action" "team_content_safety_write" {
  for_each    = local.overrides_enabled ? { this = {} } : {}
  type        = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  resource_id = "${var.apim_id}/policyFragments/ai-team-content-safety"
  method      = "PUT"

  body = {
    properties = {
      format = "xml"
      value  = local.team_cs_xml
    }
  }

  locks = ["${var.apim_id}/policyFragments/ai-team-content-safety"]

  lifecycle {
    replace_triggered_by = [terraform_data.team_content_safety_rev["this"]]
  }

  depends_on = [terraform_data.registry_guard, terraform_data.overrides_guard]
}

resource "azapi_resource_action" "team_content_safety_reset" {
  for_each    = local.overrides_enabled ? { this = {} } : {}
  type        = "Microsoft.ApiManagement/service/policyFragments@2024-06-01-preview"
  resource_id = "${var.apim_id}/policyFragments/ai-team-content-safety"
  method      = "PUT"
  when        = "destroy"

  body = {
    properties = {
      format = "xml"
      value  = file("${path.module}/policies/frag-team-cs-inert.xml")
    }
  }

  locks = ["${var.apim_id}/policyFragments/ai-team-content-safety"]
}
