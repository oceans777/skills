# AGENTS.md

This repository is the entry point for the oceans777 skill system.

## Rules

- Keep this repository focused on synchronization, installation, validation, and documentation.
- Do not place skill implementation folders directly in this repository.
- Store the published first-party packages in `repos/oceans-skills/skills/`. Those directories are submodules of `oceans777/<skill-id>` except for the `git-upstream-sync-guard` and `prd-blueprint` stubs.
- Pin the same canonical repositories directly at `repos/<skill-id>/` so the entry repository records the skill repo URL and commit.
- Store community skills in `repos/community-skills/skills/`.
- Do not rename `oceans-skills` to `skills`.
- Do not commit secrets, tokens, private account details, machine-specific configuration, or private local paths.
- When changing scripts, update `README.md` and `docs/commands.md` in the same change.
- When changing repository layout, update `manifest.yaml` and `docs/repository-model.md`.
- Installation scripts must not delete local private skills.

## Verification

Run this before committing script or repository layout changes:

```sh
./oceans validate
./oceans test
./oceans status
```

On Windows, run the equivalent `oceans.ps1` commands.
