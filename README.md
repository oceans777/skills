# oceans777 Skills

This is the entry repository for all public oceans777 skills.

You only need to clone this repository. It connects to the first-party and community skill repositories, installs skills into your local Codex skill directory, and gives you one command entry point for future updates.

## Quick Start

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

## Daily Commands

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
.\oceans.ps1 validate
.\oceans.ps1 status
```

## What The Commands Do

`.\setup.ps1` is for first-time setup. It initializes submodules, installs skills, validates the repository layout, and prints the next commands.

`.\oceans.ps1 sync` pulls the entry repository and updates all skill submodules.

`.\oceans.ps1 install` installs all discovered oceans777 skills into your local Codex skills directory.

`.\oceans.ps1 validate` checks repository structure, required skill files, and third-party attribution files.

`.\oceans.ps1 status` shows Git status, submodule status, and local install target information.

## Repository Layout

```text
skills/
  setup.ps1
  oceans.ps1
  manifest.yaml
  repos/
    oceans-skills/
    community-skills/
  scripts/
    install-skills.ps1
    sync.ps1
    validate-skills.ps1
    status.ps1
  docs/
```

## Related Repositories

`oceans777/oceans-skills` stores skills created or primarily maintained by oceans777.

`oceans777/community-skills` stores third-party skills that oceans777 mirrors, adapts, or repackages with attribution.

## Install Location

Skills are installed into:

```text
$env:CODEX_HOME\skills
```

If `CODEX_HOME` is not set, skills are installed into:

```text
$HOME\.codex\skills
```

The installer does not delete local private skills.

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

```powershell
git submodule update --init --recursive
```

If PowerShell blocks script execution, review your current policy:

```powershell
Get-ExecutionPolicy -List
```

For a normal personal Windows machine, this often fixes local script execution:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```
