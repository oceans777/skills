# AGENTS.md

This repository is the entry point for the oceans777 skill system.

## Rules

- Keep this repository focused on synchronization, installation, validation, and documentation.
- Do not place skill implementation folders directly in this repository.
- Store first-party skills in `repos/oceans-skills/skills/`.
- Store community skills in `repos/community-skills/skills/`.
- Do not commit secrets, tokens, private account details, machine-specific configuration, or private local paths.
- When changing scripts, update `README.md` and `docs/commands.md` in the same change.
- When changing repository layout, update `manifest.yaml` and `docs/repository-model.md`.
- Installation scripts must not delete local private skills.

## Verification

Run this before committing script or repository layout changes:

```powershell
.\oceans.ps1 validate
.\oceans.ps1 status
```
