# oceans777 Skills

This is the entry repository for all public oceans777 skills.

You only need to clone this repository. It connects to the first-party and community skill repositories, installs skills into your local Codex skill directory, and gives you one command entry point for future updates.

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

## What The Commands Do

`setup.ps1` and `setup.sh` are for first-time setup. They initialize the child repositories under `repos/`, validate the repository layout, install skills, and print the next commands.

`oceans.ps1 sync` and `./oceans sync` pull the entry repository and update child repositories to the versions pinned by this repository.

`oceans.ps1 install` and `./oceans install` install all discovered oceans777 skills into your local Codex skills directory.

`oceans.ps1 validate` and `./oceans validate` check repository structure, required skill files, and third-party attribution files.

`oceans.ps1 status` and `./oceans status` show Git status, submodule status, and local install target information.

`oceans.ps1 import` and `./oceans import` scan your local Codex skills and print a review report for deciding what can be moved into oceans777 repositories. The import command is report-only: it does not copy files, delete files, commit, or push.

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
  docs/
```

## Related Repositories

`oceans777/oceans-skills` stores skills created or primarily maintained by oceans777.

`oceans777/community-skills` stores third-party skills that oceans777 mirrors, adapts, or repackages with attribution.

## Install Location

Skills are installed into:

```text
CODEX_HOME/skills
```

If `CODEX_HOME` is not set, skills are installed into:

```text
$HOME/.codex/skills
```

The installer does not delete local private skills.

## Review Local Skills For Import

Use this before moving local skills into GitHub:

Windows:

```powershell
.\oceans.ps1 import
```

Ubuntu and macOS:

```sh
./oceans import
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
review-source       -> choose oceans-skills, community-skills, or do not publish
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
