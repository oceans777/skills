# Skill Sync Policy

The installer resolves the local Codex skills directory in this order:

```text
1. $env:CODEX_HOME\skills
2. $HOME\.codex\skills
```

The installer manages only skills installed from oceans777 repositories. It must not delete local private skills.

Before replacing a managed skill, the installer resolves the install root and target skill path to absolute paths and verifies the target path is inside the install root.

Each installed oceans777 skill should include a marker file:

```text
.oceans-skill-source
```

The marker records source repository and source path:

```text
source_repository=oceans-skills
source_path=repos/oceans-skills/skills/example-skill
```

This allows future updates to replace managed skills while leaving unrelated local skills alone.
