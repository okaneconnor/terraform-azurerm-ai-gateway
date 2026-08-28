# Admission — all that is needed to grant access.
variable "gateway_app_object_id" { type = string }
variable "gateway_app_role_id" { type = string }
variable "tier_names" { type = list(string) }

# The overrides seam. Set apim_id to null to run admission-only, in which case
# every admitted caller gets the gateway's default tier preset (v1 behaviour).
variable "apim_id" {
  type    = string
  default = null
}
variable "tier_limits" {
  type    = map(any)
  default = null
}
variable "canonical_models" {
  type    = list(string)
  default = null
}
variable "model_map" {
  type    = map(string)
  default = null
}
variable "rate_limit_renewal_seconds" {
  type    = number
  default = 60
}
variable "content_safety" {
  type    = any
  default = null
}