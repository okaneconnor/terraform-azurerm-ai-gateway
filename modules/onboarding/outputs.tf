output "onboarded_services" {
  description = "Every onboarded service: team, service, tier, client id and the assignment id — keyed by `<team>-<service>`."
  value = { for k, a in azuread_app_role_assignment.service : k => {
    team                = local.services[index(local.derived_keys, k)].team
    service             = local.services[index(local.derived_keys, k)].service
    tier                = [for t in local.teams : t.tier if t.team == local.services[index(local.derived_keys, k)].team][0]
    client_id           = local.services[index(local.derived_keys, k)].client_id
    principal_object_id = a.principal_object_id
    assignment_id       = a.id
  } }
}

output "effective_policies" {
  description = "The merged (service > team > defaults > tier preset / platform) policy each registered service actually gets — the audit view of the overrides seam. Null unless apim_id is set. content_safety.overridden = false means the platform fragment applies unchanged."
  value = local.overrides_enabled ? { for k, e in local.effective : k => {
    team           = e.team
    service        = e.service
    tier           = e.tier
    client_id      = e.client_id
    limits         = e.limits
    allowed_models = e.allowed_models
    content_safety = e.cs
  } } : null
}

output "teams" {
  description = "The normalised registry teams (team, owner, tier, service count) — for dashboards and downstream config."
  value = [for t in local.teams : {
    team     = t.team
    owner    = t.owner
    tier     = t.tier
    services = length(t.services)
  }]
}
