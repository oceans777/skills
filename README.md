# oceans777 Skills

This is the entry repository for all public oceans777 skills.

You only need to clone this repository. It connects to the first-party and community skill repositories, installs skills into local agent skill directories, and gives you one command entry point for future updates.

## Quick Start

### Windows

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

### Ubuntu

```sh
git clone https://github.com/oceans777/skills.git
cd skills
./setup.sh
```

### macOS

```sh
git clone https://github.com/oceans777/skills.git
cd skills
./setup.sh
```

These are the recommended setup flows. `setup.ps1` and `setup.sh` initialize the child repositories for you, so you do not need to run `git clone --recurse-submodules`.

## What Gets Cloned

`oceans777/skills` is the entry repository. It references these child repositories as Git submodules:

```text
repos/oceans-skills      -> oceans777/oceans-skills
repos/community-skills   -> oceans777/community-skills
```

After setup finishes, all three repositories are available locally:

```text
skills/
  repos/
    oceans-skills/
    community-skills/
```

`git clone --recurse-submodules` means "clone the main repository and its child repositories at the same time." It is valid Git, but it is not required here because setup runs the submodule initialization step.

## Daily Commands

### Windows

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
.\oceans.ps1 validate
.\oceans.ps1 status
.\oceans.ps1 import
```

### Ubuntu and macOS

```sh
./oceans sync
./oceans install
./oceans validate
./oceans status
./oceans import
```

Normal users only need setup plus these daily commands. `import` is a report for reviewing local skills; `stage` and `publish` are maintainer-only commands for publishing open-source skills.

## What The Commands Do

`setup.ps1` and `setup.sh` are for first-time setup. They initialize the child repositories under `repos/`, validate the repository layout, install skills, and print the next commands.

`oceans.ps1 sync` and `./oceans sync` pull the entry repository and update child repositories to the versions pinned by this repository.

`oceans.ps1 install` and `./oceans install` install all discovered oceans777 skills into your local Codex skills directory by default. You can target another runtime with `-Runtime` / `--runtime`, or install to every existing known runtime with `-AllExistingRuntimes` / `--all-existing-runtimes`. Local unmanaged skills always win: a repository skill will not overwrite an existing local skill unless that local skill has an oceans777 source marker.

`oceans.ps1 validate` and `./oceans validate` check repository structure, required skill files, third-party attribution files, and cross-repository skill name uniqueness.

`oceans.ps1 status` and `./oceans status` show Git status, submodule status, and local install target information.

`oceans.ps1 import` and `./oceans import` scan existing local skill roots for Codex, agents, Claude, OpenClaw, and Hermes, then print a review report for deciding what can be moved into oceans777 repositories. The import command is report-only: it does not copy files, delete files, commit, or push.

## Maintainer Skill Publishing

This flow is for maintainers publishing open-source skills into the oceans777 first-party or community repositories. Normal users do not need `stage` or `publish`.

Review local skills first:

Windows:

```powershell
.\oceans.ps1 import
```

Ubuntu and macOS:

```sh
./oceans import
```

Stage exactly one reviewed skill into a target repository:

Windows:

```powershell
.\oceans.ps1 stage -SourceRoot "$HOME/.codex/skills" -Skill frontend-design -Target oceans
.\oceans.ps1 stage -Runtime agents -Skill discuz-x5 -Target oceans
```

Ubuntu and macOS:

```sh
./oceans stage --source-root "$HOME/.codex/skills" --skill frontend-design --target oceans
./oceans stage --runtime agents --skill discuz-x5 --target oceans
```

Publish after validation and review:

Windows:

```powershell
.\oceans.ps1 publish
```

Ubuntu and macOS:

```sh
./oceans publish
```

`stage` copies one explicitly named local skill into either the first-party or community repository after safety checks. `publish` validates staged skill changes, commits child repository updates when needed, updates submodule pins, and pushes normal `main` branches.

Publishing safety defaults:

```text
stage requires an explicit single skill name
stage does not overwrite an existing repository skill unless replace-existing is requested
stage blocks risky content unless allow-risk is requested
stage rejects symlinks and reparse points instead of dereferencing them
community skills require non-empty upstream, patch, and license records before publishing
publish only pushes allowed skill changes and entry submodule pointer changes
publish never force-pushes
```

## Repository Layout

```text
skills/
  setup.ps1
  setup.sh
  oceans.ps1
  oceans
  manifest.yaml
  repos/
    oceans-skills/
    community-skills/
  scripts/
    install-skills.ps1
    install-skills.sh
    sync.ps1
    sync.sh
    validate-skills.ps1
    validate-skills.sh
    status.ps1
    status.sh
    import-skills.ps1
    import-skills.sh
    stage-skill.ps1
    stage-skill.sh
    publish-skills.ps1
    publish-skills.sh
  docs/
```

## Related Repositories

`oceans777/oceans-skills` stores skills created or primarily maintained by oceans777.

`oceans777/community-skills` stores third-party skills that oceans777 mirrors, adapts, or repackages with attribution.

Skill folder names must be unique across both repositories. The local install directory is flat, so `repos/oceans-skills/skills/example/` and `repos/community-skills/skills/example/` would collide during installation. `validate` rejects cross-repository duplicates before they can be published.

## Runtime Skill Roots

The root registry recognizes these local runtime skill directories:

```text
codex    -> CODEX_HOME/skills or $HOME/.codex/skills
agents   -> AGENTS_HOME/skills or $HOME/.agents/skills
claude   -> CLAUDE_HOME/skills or $HOME/.claude/skills
openclaw -> OPENCLAW_HOME/skills or $HOME/.openclaw/skills or $HOME/.config/openclaw/skills
hermes   -> HERMES_HOME/skills or $HOME/.hermes/skills or $HOME/.config/hermes/skills
```

Default setup and install are conservative: they install into Codex only.

Install into a specific runtime:

Windows:

```powershell
.\oceans.ps1 install -Runtime claude
```

Ubuntu and macOS:

```sh
./oceans install --runtime claude
```

Install into every runtime root that already exists:

Windows:

```powershell
.\oceans.ps1 install -AllExistingRuntimes
```

Ubuntu and macOS:

```sh
./oceans install --all-existing-runtimes
```

The installer does not delete local private skills and does not create missing non-Codex runtime directories unless you explicitly target that runtime.

## Local-First Duplicate Policy

Local skills always win over repository skills with the same folder name.

```text
Local skill has no .oceans-skill-source marker
  -> duplicate-local-wins; keep the local skill and skip the repository copy

Local skill has .oceans-skill-source from the same oceans777 repository
  -> managed by oceans777; update from that repository

Local skill has .oceans-skill-source from a different oceans777 repository
  -> duplicate-managed-source-mismatch; keep the local skill and ask for manual review

Local skill has .oceans-skill-source from an unknown source
  -> duplicate-unknown-marker; keep the local skill and ask for manual review
```

This protects private or manually installed skills from being overwritten by `setup` or `install`.

## Review Local Skills For Import

Use this before moving local skills into GitHub:

Windows:

```powershell
.\oceans.ps1 import
.\oceans.ps1 import -Runtime claude
```

Ubuntu and macOS:

```sh
./oceans import
./oceans import --runtime claude
```

To scan a different skills directory:

Windows:

```powershell
.\oceans.ps1 import -SourceRoot "C:\path\to\skills"
```

Ubuntu and macOS:

```sh
./oceans import --source-root "$HOME/.codex/skills"
```

The report classifies local skills as:

```text
skip-system         -> do not publish Codex system skills
missing-skill-md    -> repair before import
already-managed     -> already has an oceans777 source marker
duplicate-local-wins -> local skill matches a repository skill, but the local copy wins
duplicate-local-runtime -> the same local skill name exists in more than one runtime root
review-source       -> choose oceans-skills, community-skills, or do not publish
```

When a local skill name already exists in the repository, the report includes:

```text
repository_match: oceans-skills or community-skills
local_runtime_match: codex, agents, claude, openclaw, or hermes
action: keep local skill; repository version will not overwrite it
```

For `review-source` items, use this rule:

```text
Created by oceans777        -> repos/oceans-skills/skills/<skill-name>/
Forked or adapted from other authors -> repos/community-skills/skills/<skill-name>/
Private or source unclear   -> do not publish yet
```

The report also flags secret-like text and local absolute paths so you can review them before publishing.

## Add A First-Party Skill

Create a new folder in:

```text
repos/oceans-skills/skills/<skill-name>/
```

Each skill must include:

```text
SKILL.md
```

Skill names should use lowercase letters, digits, and hyphens.

## Add A Community Skill

Create a new folder in:

```text
repos/community-skills/skills/<safe-skill-name>/
```

Each community skill must include:

```text
SKILL.md
UPSTREAM.md
PATCHES.md
LICENSE
```

Use `UPSTREAM.md` to record the original repository, author, license, import date, and local changes.

## Troubleshooting

If submodules are missing, run:

Windows:

```powershell
git submodule update --init --recursive
```

Ubuntu and macOS:

```sh
git submodule update --init --recursive
```

If GitHub access fails while child repositories are being cloned, fix the network issue and rerun:

Windows:

```powershell
.\setup.ps1
```

Ubuntu and macOS:

```sh
./setup.sh
```

For day-to-day updates after setup, rerun:

Windows:

```powershell
.\oceans.ps1 sync
```

Ubuntu and macOS:

```sh
./oceans sync
```

If PowerShell blocks script execution, review your current policy:

```powershell
Get-ExecutionPolicy -List
```

For a normal personal Windows machine, this often fixes local script execution:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

If Ubuntu or macOS reports `Permission denied` for the shell entrypoints, restore executable permissions:

```sh
chmod +x setup.sh oceans scripts/*.sh
```
