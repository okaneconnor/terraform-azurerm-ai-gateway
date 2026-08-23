variable "registry_file" {
  description = <<-EOT
    Path to the team registry YAML — the declarative record of every team and
    service admitted to the gateway. Teams onboard, change and offboard by pull
    request against this one file; applying this module reconciles the
    assignments. See the module README for the schema.
  EOT
  type        = string
}

variable "gateway_app_object_id" {
  description = "The gateway module's `gateway_app_object_id` output — the service principal the admission role lives on."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.gateway_app_object_id))
    error_message = "gateway_app_object_id must be a GUID (the gateway module's gateway_app_object_id output)."
  }
}

variable "gateway_app_role_id" {
  description = "The gateway module's `gateway_app_role_id` output — the admission app role assigned to every onboarded service identity."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.gateway_app_role_id))
    error_message = "gateway_app_role_id must be a GUID (the gateway module's gateway_app_role_id output)."
  }
}

variable "tier_names" {
  description = "The gateway module's `tier_names` output — the preset names a team's `tier` may reference. Validated at plan so a registry can never point at a preset the gateway does not define."
  type        = list(string)

  validation {
    condition     = length(var.tier_names) > 0
    error_message = "tier_names must not be empty — pass the gateway module's tier_names output."
  }
}
