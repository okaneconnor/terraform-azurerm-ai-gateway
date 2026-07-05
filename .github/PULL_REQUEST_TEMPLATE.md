## What & why

What does this change do, and why is it needed?

Closes #<issue>

## Checklist

- [ ] `terraform fmt` run (no diff)
- [ ] `terraform validate` passes
- [ ] `terraform test` passes (`terraform init -backend=false && terraform test`)
- [ ] Docs regenerated if inputs/outputs changed (`terraform-docs`; the
      `BEGIN_TF_DOCS`/`END_TF_DOCS` block in the README is regenerated, not hand-edited)
- [ ] No breaking changes (or breaking changes are documented in the PR body and `CHANGELOG.md`)
- [ ] Relevant docs updated (`docs/usage.md`, `docs/onboarding.md`, `docs/architecture.md`, etc.)

## Breaking changes

List any input/output renames, removals, or default changes, and the migration path.
Write "None" if there are none.
