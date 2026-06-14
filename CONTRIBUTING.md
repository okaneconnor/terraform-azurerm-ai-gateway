# Contributing

Thanks for contributing! This is a reusable Terraform module — keep it generic,
keep nothing hardcoded that a consumer might reasonably want to change, and keep
the docs and tests in step with the code.

## Prerequisites

```bash
brew install terraform terraform-docs tfsec checkov pre-commit
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
terraform test                                # 20 plan-mode unit tests (mocked providers)
terraform-docs .                              # regenerate the README Inputs/Outputs block
bash scripts/scan.sh                          # tfsec + checkov (fails closed if neither installed)
```

Validate the examples too:

```bash
for d in examples/basic examples/complete; do
  ( cd "$d" && terraform init -backend=false && terraform validate )
done
```

### Pre-commit

A [`.pre-commit-config.yaml`](.pre-commit-config.yaml) wires `fmt` → `validate` →
`terraform-docs` → `tfsec` → `checkov` plus basic hygiene hooks. Enable it once:

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

Both `tfsec` and `checkov` must pass. Genuine false positives or deliberate design
choices are suppressed **inline** next to the resource with a documented
`#checkov:skip=<ID>:<reason>` comment — never blanket-disable a check globally.

## Pull requests

- Keep changes focused; one logical change per PR.
- Use clear, conventional commit messages (`feat:`, `fix:`, `docs:`, `ci:`, …).
- Ensure all local checks above pass; the CI workflow gates the same way.
- If you change inputs/outputs, regenerate the docs block in the same PR.
