# Multi-Runtime Skill Roots Design

## Goal

`oceans777/skills` must correctly find, classify, publish, and install skills across multiple local agent runtimes, not only Codex. The repository remains the single Git clone entry point, while local runtime placement is explicit and safe.

## Supported Runtimes

The first registry version supports these runtime ids:

```text
codex
agents
claude
openclaw
hermes
custom
```

Default roots:

```text
codex    -> CODEX_HOME/skills or ~/.codex/skills
agents   -> AGENTS_HOME/skills or ~/.agents/skills
claude   -> CLAUDE_HOME/skills or ~/.claude/skills
openclaw -> OPENCLAW_HOME/skills or ~/.openclaw/skills, ~/.config/openclaw/skills
hermes   -> HERMES_HOME/skills or ~/.hermes/skills, ~/.config/hermes/skills
custom   -> explicit user path only
```

Only existing roots are scanned or installed to automatically. Missing runtime directories are reported as missing when listing roots, but setup/install must not create random tool directories unless the user explicitly targets that runtime.

## Command Behavior

`import` changes from single-root-by-default to multi-root discovery:

```text
oceans import
```

scans every existing known runtime skill root and prints `runtime`, `source_root`, and `source_path` for each skill. Duplicate names across local runtimes are reported as `duplicate-local-runtime` so maintainers can choose the correct source before staging.

`stage` keeps `SourceRoot` / `--source-root` for exact paths and adds runtime selection:

```text
.\oceans.ps1 stage -Runtime agents -Skill discuz-x5 -Target oceans
./oceans stage --runtime agents --skill discuz-x5 --target oceans
```

If both runtime and source root are provided, source root wins and the report/runtime label becomes `custom`. This makes unusual paths explicit.

`install` adds runtime selection:

```text
.\oceans.ps1 install
.\oceans.ps1 install -Runtime claude
.\oceans.ps1 install -AllExistingRuntimes
./oceans install
./oceans install --runtime claude
./oceans install --all-existing-runtimes
```

Default install remains conservative: Codex only, matching current behavior and avoiding writes to tools the user did not ask for. `--all-existing-runtimes` installs into every existing known root. `custom` install requires an explicit install root.

## Safety Rules

Local unmanaged skills always win inside each runtime root. Repository skills may update only directories marked with `.oceans-skill-source` from the same oceans777 repository.

Root resolution must prevent path traversal. Install and stage operations resolve final paths before deleting or copying and ensure they stay inside the selected root.

GitHub storage remains runtime-neutral:

```text
repos/oceans-skills/skills/<skill-name>/
repos/community-skills/skills/<skill-name>/
```

Runtime metadata belongs in install markers and import reports, not in repository layout. This keeps one source copy installable into Codex, Claude, OpenClaw, Hermes, or future compatible runtimes.

## Files

Create:

```text
scripts/skill-roots.ps1
scripts/skill-roots.sh
scripts/test-skill-roots.ps1
scripts/test-skill-roots.sh
```

Modify:

```text
scripts/import-skills.ps1
scripts/import-skills.sh
scripts/install-skills.ps1
scripts/install-skills.sh
scripts/stage-skill.ps1
scripts/stage-skill.sh
oceans.ps1
oceans
README.md
docs/commands.md
docs/skill-sync-policy.md
```

## Acceptance Criteria

1. `import` reports runtime/root/path for Codex, agents, Claude, OpenClaw, and Hermes roots that exist.
2. `import` flags same skill names installed in multiple local runtime roots.
3. `stage -Runtime agents` and `./oceans stage --runtime agents` stage from the agents root without requiring a raw path.
4. `install -Runtime claude` and `./oceans install --runtime claude` install to the Claude root and preserve local-first duplicate handling.
5. Default `setup` and `install` continue to install only into Codex unless the user opts into another runtime or all existing runtimes.
6. Docs explain where skills are scanned from, where GitHub stores them, and where downloads are installed.
