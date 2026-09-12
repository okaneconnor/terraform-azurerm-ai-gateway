output "onboarded_services" {
  description = "Every admitted service, keyed <team>-<service>."
  value       = module.onboarding.onboarded_services
}

output "effective_policies" {
  description = "The fully merged limits, allowlist and content-safety settings each service actually gets — the audit view."
  value       = module.onboarding.effective_policies
}