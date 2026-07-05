# Security policy

## Supported versions

This module follows the latest release. Security fixes are made against the
current `main` line and shipped in the next tagged release; older tags are not
back-patched. Pin to a released tag and upgrade to pick up fixes.

## Reporting a vulnerability

Please report security issues privately. **Do not open a public GitHub issue or
pull request for a security report** — that discloses the problem before a fix
is available.

Use GitHub private security advisories:

1. Go to the repository at https://github.com/okaneconnor/terraform-azurerm-ai-gateway
2. Open the **Security** tab and choose **Report a vulnerability** to file a
   private advisory.

Include the affected version or commit, a description of the issue, and steps to
reproduce or a proof of concept where possible.

## Scope

In scope:

- The Terraform module itself (the `*.tf` configuration and its logic).
- The APIM policies shipped in `policies/` and the policy fragments the module
  applies.

Out of scope: vulnerabilities in Azure platform services, the Terraform
`azurerm`/`azapi` providers, or other upstream dependencies. Please report those
to their respective maintainers; if a module default makes such an issue worse,
that configuration aspect is in scope.

## Response

This project is maintained by a single maintainer on a best-effort basis.
Reports will be acknowledged and remediated as time allows; there is no
guaranteed response or fix time. Thank you for reporting responsibly.
