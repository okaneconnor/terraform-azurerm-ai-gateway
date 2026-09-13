# Contributing

Thanks for contributing! This is a reusable Terraform module — keep it generic,
keep nothing hardcoded that a consumer might reasonably want to change, and keep
the docs and tests in step with the code.

## Prerequisites

```bash
brew install terraform terraform-docs trivy checkov pre-commit
```

- Terraform >= 1.9
- Azure providers are configured by the **caller**; the module only pins
  `required_providers` (see `versions.tf`).

## Local checks

Run these before opening a PR — CI runs the same set:

```bash
terraform fmt -recursive                      # format
terraform init -backend=false                 # init without a backend / creds
terraform validate                            # validate the module
terraform test                                # root unit tests (mocked providers)

terraform -chdir=modules/onboarding init -backend=false
terraform -chdir=modules/onboarding test      # the onboarding submodule has its OWN suite

terraform-docs .                              # regenerate the README Inputs/Outputs block
trivy config . && checkov -d .                # static analysis (or: pre-commit run -a)
```

### Pre-commit

A [`.pre-commit-config.yaml`](.pre-commit-config.yaml) wires `fmt` → `validate` →
`terraform-docs` → `trivy` → `checkov` plus basic hygiene hooks. Enable it once:

```bash
pre-commit install
pre-commit run -a    # run against everything on demand
```

## Documentation

- The **Requirements / Providers / Resources / Inputs / Outputs** tables in the
  README are generated — never hand-edit them. Run `terraform-docs .` after changing
  any variable or output. CI fails if the block is stale.
- Narrative docs live under [`docs/`](docs/). Update the relevant page
  (`architecture.md`, `usage.md`, `operations.md`) when behaviour changes.
- Record notable changes in [CHANGELOG.md](CHANGELOG.md).

## Static analysis

Both `trivy config` and `checkov` must pass. Genuine false positives or deliberate design
choices are suppressed **inline** next to the resource with a documented
`#checkov:skip=<ID>:<reason>` comment — never blanket-disable a check globally.

## What gets merged

- **Plan-mode tests are always required.** Every validation rule needs a failing-case
  test; every behaviour worth claiming needs an assertion that would fail if the
  behaviour were removed. Both suites must be green — the root one and
  `modules/onboarding`.
- Both suites are also run against the **Terraform version floor** (see `TF_VERSION`
  in `.github/workflows/ci.yml`). `||` and `&&` do not short-circuit on 1.9.x, so
  expressions that pass on current Terraform can still fail there.
- **Live verification is maintainer-run.** Changes that alter runtime behaviour are
  verified against a real deployment with `scripts/verify-live.sh` before release;
  you are not expected to hold an Azure subscription to contribute.
- Docs are part of the change, not a follow-up. CI fails on a stale terraform-docs
  block; the narrative docs are reviewed by hand.

## Pull requests

- Keep changes focused; one logical change per PR.
- Use clear, conventional commit messages (`feat:`, `fix:`, `docs:`, `ci:`, …).
- Ensure all local checks above pass; the CI workflow gates the same way.
- If you change inputs/outputs, regenerate the docs block in the same PR.
