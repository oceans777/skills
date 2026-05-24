# Skill Sync Policy

The installer uses the shared runtime root registry.

```text
codex    -> CODEX_HOME/skills or $HOME/.codex/skills
agents   -> AGENTS_HOME/skills or $HOME/.agents/skills
claude   -> CLAUDE_HOME/skills or $HOME/.claude/skills
openclaw -> OPENCLAW_HOME/skills or $HOME/.openclaw/skills or $HOME/.config/openclaw/skills
hermes   -> HERMES_HOME/skills or $HOME/.hermes/skills or $HOME/.config/hermes/skills
custom   -> explicit path only
```

Default `setup` and `install` target Codex only. `install -Runtime <runtime>` targets one runtime and creates that runtime root if needed. `install -AllExistingRuntimes` installs only into known runtime roots that already exist.

The installer manages only skills installed from oceans777 repositories. It must not delete local private skills.

Before replacing a managed skill, the installer resolves the install root and target skill path to absolute paths and verifies the target path is inside the install root.

Each installed oceans777 skill includes a marker file:

```text
.oceans-skill-source
```

The marker records source repository, repository source path, target runtime, and install root:

```text
source_repository=oceans-skills
source_path=repos/oceans-skills/skills/example-skill
runtime=codex
install_root=/home/example/.codex/skills
```

This allows future updates to replace managed skills while leaving unrelated local skills alone.
