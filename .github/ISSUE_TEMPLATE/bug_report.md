---
name: Bug report
about: Report a defect in the module (unexpected plan/apply behaviour, wrong output)
title: "[bug] "
labels: bug
---

## Description

A clear, concise description of the bug and its impact.

## Versions

- Module version (tag or commit):
- Terraform version (`terraform version`):
- Provider versions (`azurerm`, `azuread`, `azapi`):

## Reproduction config

The smallest `module` block (and relevant inputs) that reproduces the issue.
Redact secrets and tenant/subscription IDs.

```hcl
module "ai_gateway" {
  source = "github.com/okaneconnor/ai-gateway"

  # ...
}
```

## Expected vs actual

- **Expected:** what you thought would happen.
- **Actual:** what actually happened.

## Plan / apply output

Relevant `terraform plan` / `terraform apply` output or error. Redact secrets.

```text

```

## Additional context

Anything else that helps — region, network mode (Internal/External), etc.
