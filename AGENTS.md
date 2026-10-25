# AGENTS.md

This repository is the entry point for the oceans777 skill system.

## Rules

- Keep this repository focused on synchronization, installation, validation, and documentation.
- Do not place skill implementation folders directly in this repository.
- Store each published first-party skill as its own repository at `repos/<skill-id>/`, pinned to `https://github.com/oceans777/<skill-id>`.
- Keep `prd-blueprint` and `git-upstream-sync-guard` as archived catalog stubs that point at `prd-skill` and `fork-skill`. Do not recreate an aggregate package for them.
- Store community skills in `repos/community-skills/skills/`.
- Do not add `oceans777/oceans-skills` back as an install or catalog dependency. That aggregate is retired.
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
