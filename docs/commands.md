# Commands

## First-Time Setup

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

These are the recommended flows. Do not require users to type `--recurse-submodules`; setup initializes the child repositories after the main repository is cloned.

`setup.ps1` and `setup.sh` initialize `repos/oceans-skills` and `repos/community-skills`, validate structure, install skills, and print next steps.

## About `--recurse-submodules`

This command is valid Git:

```powershell
git clone --recurse-submodules https://github.com/oceans777/skills.git
```

It clones the entry repository and its child repositories in one Git command. In this project, the simpler user-facing flow is preferred.

Windows:

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

Ubuntu and macOS:

```sh
git clone https://github.com/oceans777/skills.git
cd skills
./setup.sh
```

Both approaches can result in all repositories being present locally. The setup flow is easier to remember and also runs validation and installation.

`setup.ps1`, `setup.sh`, `oceans.ps1 sync`, and `./oceans sync` retry remote Git operations to handle temporary network failures. If GitHub is unreachable after the retries, fix the network issue and rerun the same command.

## Daily Usage

### Windows

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
.\oceans.ps1 validate
.\oceans.ps1 status
.\oceans.ps1 import
.\oceans.ps1 stage
.\oceans.ps1 publish
```

### Ubuntu and macOS

```sh
./oceans sync
./oceans install
./oceans validate
./oceans status
./oceans import
./oceans stage
./oceans publish
```

## Command Reference

`sync` updates the entry repository and checks out child repositories at the versions pinned by the entry repository.

`install` installs skills into the local Codex skills directory. Local unmanaged skills always win and are not overwritten by repository skills with the same name.

`validate` checks skill structure, required files, and third-party attribution.

`status` prints repository state, submodule state, and install target state.

`import` scans local Codex skills and prints a review-only classification report. It never copies, deletes, commits, or pushes files.

`stage` copies one explicitly named local skill into either `repos/oceans-skills` or `repos/community-skills` after validation and safety checks.

`publish` validates staged skill changes, commits child repository skill updates when needed, updates submodule pins in the entry repository, and pushes normal `main` branches. It never force-pushes.

## Maintainer Publishing Flow

Review local skills:

Windows:

```powershell
.\oceans.ps1 import
```

Ubuntu and macOS:

```sh
./oceans import
```

Stage one reviewed skill:

Windows:

```powershell
.\oceans.ps1 stage -SourceRoot "$HOME/.codex/skills" -Skill frontend-design -Target oceans
```

Ubuntu and macOS:

```sh
./oceans stage --source-root "$HOME/.codex/skills" --skill frontend-design --target oceans
```

Publish staged changes:

Windows:

```powershell
.\oceans.ps1 publish
```

Ubuntu and macOS:

```sh
./oceans publish
```

Safety defaults:

```text
explicit single skill only
no default overwrite
no default risky content
community requires real upstream/license records
publish never force-pushes
```

## Local-First Duplicate Policy

```text
Local skill has no .oceans-skill-source marker
  -> duplicate-local-wins; keep the local skill and skip the repository copy

Local skill has .oceans-skill-source from oceans-skills or community-skills
  -> managed by oceans777; update from the repository

Local skill has .oceans-skill-source from an unknown source
  -> duplicate-unknown-marker; keep the local skill and ask for manual review
```

## Import Review

Default local scan:

Windows:

```powershell
.\oceans.ps1 import
```

Ubuntu and macOS:

```sh
./oceans import
```

Custom source directory:

Windows:

```powershell
.\oceans.ps1 import -SourceRoot "C:\path\to\skills"
```

Ubuntu and macOS:

```sh
./oceans import --source-root "$HOME/.codex/skills"
```

Report statuses:

```text
skip-system         -> do not publish Codex system skills
missing-skill-md    -> repair before import
already-managed     -> already has an oceans777 source marker
duplicate-local-wins -> local skill matches a repository skill, but the local copy wins
review-source       -> choose oceans-skills, community-skills, or do not publish
```

Duplicate report fields:

```text
repository_match: oceans-skills or community-skills
action: keep local skill; repository version will not overwrite it
```

`help` prints available commands.
