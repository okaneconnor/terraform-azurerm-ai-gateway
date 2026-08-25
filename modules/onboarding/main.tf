# Declarative team onboarding for the AI gateway, in its own Terraform state.
#
# The registry YAML is the single source of truth: a team present in the file is
# onboarded, a team removed is deprovisioned on the next apply. This module holds
# azuread resources ONLY — an onboarding apply needs Entra permissions, never
# gateway credentials, and can never plan the gateway itself.

locals {
  raw = yamldecode(file(var.registry_file))

  # ── Normalisation ───────────────────────────────────────────────────────────
  # Every field is read with try() so a malformed registry fails on the ONE
  # precondition that names its actual problem, instead of crashing evaluation of
  # every rule at once.
  team_allowed_keys    = ["team", "owner", "tier", "services"]
  service_allowed_keys = ["service", "client_id", "principal_object_id"]

  teams = [for t in try(local.raw.teams, []) : {
    team         = try(t.team, null)
    owner        = try(t.owner, null)
    tier         = try(t.tier, null)
    services     = try(t.services, [])
    unknown_keys = setsubtract(keys(t), local.team_allowed_keys)
  }]

  services = flatten([
    for t in local.teams : [
      for s in t.services : {
        team                = t.team
        service             = try(s.service, null)
        client_id           = try(s.client_id, null)
        principal_object_id = try(s.principal_object_id, null)
        key                 = "${coalesce(t.team, "_")}-${coalesce(try(s.service, null), "_")}"
        unknown_keys        = setsubtract(keys(s), local.service_allowed_keys)
      }
    ]
  ])

  # Derived-id uniqueness has to hold for the WHOLE key, not just per pair:
  # team "a" + service "b-c" and team "a-b" + service "c" both derive "a-b-c",
  # and a Terraform for_each would silently collapse them into one resource —
  # one team quietly receiving another's assignment.
  derived_keys = [for s in local.services : s.key]

  # Shapes shared by several rules.
  kebab_re = "^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$"
  guid_re  = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  all_ids = flatten([for s in local.services : [
    { kind = "client_id", value = s.client_id, where = s.key },
    { kind = "principal_object_id", value = s.principal_object_id, where = s.key },
  ]])

  # A GUID whose every dash-group is one repeated character (11111111-2222-…) is
  # a copied documentation example, not a real Entra id.
  # coalesce guards the split: HCL's && does not short-circuit on Terraform
  # 1.9.x (this module's floor), so without it a null id errors here instead of
  # failing the required-fields rule with its proper message.
  placeholder_ids = [for i in local.all_ids : i if i.value != null && can(regex(local.guid_re, i.value)) && alltrue([
    for g in split("-", coalesce(i.value, "x")) : length(distinct(split("", g))) == 1
  ])]

  principal_teams = { for s in local.services : s.principal_object_id => distinct([
    for x in local.services : x.team if x.principal_object_id == s.principal_object_id
  ])... if s.principal_object_id != null }
}

# Every rule is a resource precondition: preconditions HARD-fail the plan (check
# blocks only warn outside terraform test), and each message names the offending
# entry so a team can fix its own PR without platform help.
resource "terraform_data" "registry_guard" {
  lifecycle {
    precondition {
      condition     = try(local.raw.version, null) == "v1"
      error_message = "Registry version must be \"v1\" (got: ${try(tostring(local.raw.version), "missing")})."
    }
    precondition {
      condition     = length(setsubtract(keys(local.raw), ["version", "teams"])) == 0
      error_message = "Unknown top-level registry key(s): ${join(", ", setsubtract(keys(local.raw), ["version", "teams"]))}. Allowed: version, teams. A misspelled key would be silently ignored otherwise — that is why this fails."
    }
    precondition {
      condition     = alltrue([for t in local.teams : length(t.unknown_keys) == 0])
      error_message = "Unknown key(s) on team entries: ${join("; ", [for t in local.teams : "team ${coalesce(t.team, "?")}: ${join(", ", t.unknown_keys)}" if length(t.unknown_keys) > 0])}. Allowed: ${join(", ", local.team_allowed_keys)}."
    }
    precondition {
      condition     = alltrue([for s in local.services : length(s.unknown_keys) == 0])
      error_message = "Unknown key(s) on service entries: ${join("; ", [for s in local.services : "${s.key}: ${join(", ", s.unknown_keys)}" if length(s.unknown_keys) > 0])}. Allowed: ${join(", ", local.service_allowed_keys)}."
    }
    precondition {
      condition     = alltrue([for t in local.teams : t.team != null && t.owner != null && t.tier != null && length(t.services) > 0])
      error_message = "Team entries missing required fields (team, owner, tier, non-empty services): ${join(", ", [for i, t in local.teams : coalesce(t.team, "entry ${i}") if t.team == null || t.owner == null || t.tier == null || length(t.services) == 0])}."
    }
    precondition {
      condition     = alltrue([for s in local.services : s.service != null && s.client_id != null && s.principal_object_id != null])
      error_message = "Service entries missing required fields (service, client_id, principal_object_id): ${join(", ", [for s in local.services : s.key if s.service == null || s.client_id == null || s.principal_object_id == null])}."
    }
    precondition {
      condition     = alltrue([for t in local.teams : t.team == null || can(regex(local.kebab_re, t.team))])
      error_message = "Team names must be lowercase kebab-case (1-32 chars, no leading/trailing hyphen): ${join(", ", [for t in local.teams : tostring(t.team) if t.team != null && !can(regex(local.kebab_re, t.team))])}."
    }
    precondition {
      condition     = alltrue([for s in local.services : s.service == null || can(regex(local.kebab_re, s.service))])
      error_message = "Service names must be lowercase kebab-case (1-32 chars, no leading/trailing hyphen): ${join(", ", [for s in local.services : tostring(s.service) if s.service != null && !can(regex(local.kebab_re, s.service))])}."
    }
    precondition {
      condition     = alltrue([for i in local.all_ids : i.value == null || can(regex(local.guid_re, i.value))])
      error_message = "Identity ids must be GUIDs: ${join("; ", [for i in local.all_ids : "${i.where} ${i.kind}=${tostring(i.value)}" if i.value != null && !can(regex(local.guid_re, i.value))])}. principal_object_id is the service principal OBJECT id, not the application id."
    }
    precondition {
      condition     = length(local.placeholder_ids) == 0
      error_message = "Placeholder GUIDs found (every dash-group a single repeated character — a copied documentation example, not a real Entra id): ${join("; ", [for i in local.placeholder_ids : "${i.where} ${i.kind}=${i.value}"])}. Substitute the identity's real ids."
    }
    precondition {
      condition     = length(distinct([for t in local.teams : t.team])) == length(local.teams)
      error_message = "Duplicate team entries: ${join(", ", distinct([for t in local.teams : tostring(t.team) if length([for x in local.teams : x if x.team == t.team]) > 1]))}. Each team appears once; a team's services all live under its single entry."
    }
    precondition {
      condition     = length(distinct(local.derived_keys)) == length(local.derived_keys)
      error_message = "Colliding team/service keys: ${join(", ", distinct([for k in local.derived_keys : k if length([for x in local.derived_keys : x if x == k]) > 1]))}. Either a duplicated service, or a hyphen-ambiguous pair (team \"a\" + service \"b-c\" vs team \"a-b\" + service \"c\") — both would silently collapse into one resource."
    }
    precondition {
      condition     = alltrue([for p, teams in local.principal_teams : length(flatten(teams)) == 1])
      error_message = "principal_object_id claimed more than once: ${join("; ", [for p, teams in local.principal_teams : "${p} (teams: ${join(", ", distinct(flatten(teams)))})" if length(flatten(teams)) > 1])}. A service = one identity; sharing an identity across services or teams would merge their attribution, limits and revocation."
    }
    precondition {
      condition     = length(distinct([for s in local.services : s.client_id])) == length(local.services)
      error_message = "client_id claimed by more than one service: ${join(", ", distinct([for s in local.services : tostring(s.client_id) if length([for x in local.services : x if x.client_id == s.client_id]) > 1]))}. The client id keys per-service limits and attribution (azp) — it cannot be shared."
    }
    precondition {
      condition     = alltrue([for t in local.teams : t.tier == null || contains(var.tier_names, t.tier)])
      error_message = "Unknown tier(s): ${join("; ", [for t in local.teams : "team ${t.team}: ${tostring(t.tier)}" if t.tier != null && !contains(var.tier_names, t.tier)])}. The gateway defines: ${join(", ", var.tier_names)}."
    }
  }
}

# The onboarding itself: one admission-role assignment per service identity.
resource "azuread_app_role_assignment" "service" {
  for_each = { for s in local.services : s.key => s }

  app_role_id         = var.gateway_app_role_id
  principal_object_id = each.value.principal_object_id
  resource_object_id  = var.gateway_app_object_id

  depends_on = [terraform_data.registry_guard]
}
