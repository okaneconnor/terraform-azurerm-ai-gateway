# APIM AI Gateway — Sandbox

Flat Terraform for an Azure API Management AI Gateway sandbox (Developer tier).
Capabilities are applied one phase at a time via `enable_*` variables.

## Prerequisites
- Terraform >= 1.9
- `az login` and a subscription selected (`az account set --subscription <id>`)
- Provider registrations: `Microsoft.ApiManagement`, `Microsoft.CognitiveServices`,
  `Microsoft.Cache` / `Microsoft.Cache/redisEnterprise`, `Microsoft.ApiCenter`

## Phased apply
1. `cp terraform.tfvars.example terraform.tfvars` and edit `publisher_email`.
2. `terraform init`
3. `terraform apply` (Phase 1 foundation — all toggles false).
4. Validate (see `test/01-chat.sh`), then set `enable_token_governance = true` and re-apply.
5. Repeat for `enable_semantic_cache`, `enable_content_safety`, `enable_mcp`,
   `enable_agents_selfservice`.

See per-phase validation and the production-hardening appendix at the bottom of this file.
