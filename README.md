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

`oceans.ps1 validate` and `./oceans validate` check repository structure, required skill files, required `SKILL.md` frontmatter, third-party attribution files, and cross-repository skill name uniqueness.

`oceans.ps1 status` and `./oceans status` show Git status, submodule status, known runtime skill roots, and managed oceans777 skill counts. Use `-Runtime` / `--runtime` to inspect one runtime, or `-AllExistingRuntimes` / `--all-existing-runtimes` to show only roots that already exist.

`oceans.ps1 import` and `./oceans import` scan existing local skill roots for Codex, agents, Claude, OpenClaw, and Hermes, then print a review report for deciding what can be moved into oceans777 repositories. Runtime environment variables are honored first, and OpenClaw/Hermes also follow `XDG_CONFIG_HOME` when present. The import command is report-only: it does not copy files, delete files, commit, or push.

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
stage validates SKILL.md name, description, and folder-name consistency
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

Inspect runtime skill roots without installing:

Windows:

```powershell
.\oceans.ps1 status
.\oceans.ps1 status -Runtime claude
.\oceans.ps1 status -AllExistingRuntimes
```

Ubuntu and macOS:

```sh
./oceans status
./oceans status --runtime claude
./oceans status --all-existing-runtimes
```

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
.\oceans.ps1 import -Format json
```

Ubuntu and macOS:

```sh
./oceans import
./oceans import --runtime claude
./oceans import --format json
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
invalid-skill-name  -> rename the local skill folder before import
invalid-skill-metadata -> repair SKILL.md frontmatter before import
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

The report also flags missing metadata, missing referenced license files, secret-like text, local absolute paths, large files, and binary or unreadable files so you can review them before publishing. Use JSON output when another script or UI needs to consume the report programmatically.

## Contribute Or Upload A Skill

Uploading is intentionally split into three steps:

```text
import  -> scan local skills and produce a report; no files are changed
stage   -> copy one reviewed local skill into oceans-skills or community-skills
publish -> validate, commit, update submodule pins, and push to GitHub
```

Choose the target repository before staging:

```text
You created and maintain the skill       -> oceans-skills
You forked or adapted another author     -> community-skills
The skill is private or source is unclear -> do not upload yet
```

### Maintainers With Write Access

Start with a scan:

Windows:

```powershell
.\oceans.ps1 import
.\oceans.ps1 import -Format json
```

Ubuntu and macOS:

```sh
./oceans import
./oceans import --format json
```

Only stage skills that are clean enough to publish. A typical first-party upload looks like this:

Windows:

```powershell
.\oceans.ps1 stage -Runtime codex -Skill my-skill -Target oceans
.\oceans.ps1 validate
.\oceans.ps1 publish
```

Ubuntu and macOS:

```sh
./oceans stage --runtime codex --skill my-skill --target oceans
./oceans validate
./oceans publish
```

If the skill is stored in a custom local directory, pass the source root explicitly:

Windows:

```powershell
.\oceans.ps1 stage -SourceRoot "C:\path\to\skills" -Skill my-skill -Target oceans
```

Ubuntu and macOS:

```sh
./oceans stage --source-root "$HOME/path/to/skills" --skill my-skill --target oceans
```

For a community skill, include upstream and license records while staging:

Windows:

```powershell
.\oceans.ps1 stage -Runtime codex -Skill third-party-skill -Target community `
  -UpstreamUrl "https://github.com/author/repo" `
  -UpstreamAuthor "Author Name" `
  -UpstreamLicense "MIT" `
  -LicenseFile "C:\path\to\LICENSE" `
  -PatchSummary "Adapted metadata and packaging for oceans777."
```

Ubuntu and macOS:

```sh
./oceans stage --runtime codex --skill third-party-skill --target community \
  --upstream-url "https://github.com/author/repo" \
  --upstream-author "Author Name" \
  --upstream-license "MIT" \
  --license-file "$HOME/path/to/LICENSE" \
  --patch-summary "Adapted metadata and packaging for oceans777."
```

Use `-AllowRisk` / `--allow-risk` only after reviewing every risk line. Use `-ReplaceExisting` / `--replace-existing` only when intentionally replacing an existing repository skill.

### Contributors Without Write Access

External contributors cannot push directly to `oceans777/skills`, `oceans777/oceans-skills`, or `oceans777/community-skills`. Use this flow instead:

```text
1. Run import locally and fix any invalid-skill or risk findings.
2. Fork the target child repository: oceans-skills for your own skill, or community-skills for a third-party skill.
3. Add the skill under skills/<skill-name>/ in your fork.
4. Run validate locally if you also cloned the entry repository.
5. Open a pull request to the target child repository.
6. After merge, oceans777 maintainers update the entry repository submodule pin.
```

For community contributions, include `UPSTREAM.md`, `PATCHES.md`, and `LICENSE` in the pull request.

### Programmatic Preflight

Use JSON output when another script or UI decides what can be uploaded:

Windows:

```powershell
$report = .\oceans.ps1 import -Format json | ConvertFrom-Json
$report.items |
  Where-Object { $_.status -eq "review-source" } |
  Select-Object name, runtime, source_path, risks
```

Ubuntu and macOS:

```sh
./oceans import --format json > import-report.json
```

A program should treat `review-source` as "needs human classification", not as automatic permission to upload. It should block or ask for repair on `invalid-skill-name`, `invalid-skill-metadata`, `missing-skill-md`, `duplicate-local-runtime`, and any non-empty risk list other than `risk: none detected`.

The implementation lives in these scripts:

```text
scripts/import-skills.ps1 / scripts/import-skills.sh   -> scan and report
scripts/stage-skill.ps1 / scripts/stage-skill.sh       -> copy one reviewed skill
scripts/publish-skills.ps1 / scripts/publish-skills.sh -> commit, pin, and push
scripts/skill-publish-rules.*                          -> shared metadata and risk rules
```

## Add A First-Party Skill

Create a new folder in:

```text
repos/oceans-skills/skills/<skill-name>/
```

Each skill must include:

```text
SKILL.md
```

`SKILL.md` must start with frontmatter whose `name` equals the folder name and whose `description` is non-empty:

```md
---
name: <skill-name>
description: <what this skill is for>
---
```

Skill names must use lowercase letters, digits, and hyphens.

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

The same `SKILL.md` frontmatter rule applies to community skills.

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
