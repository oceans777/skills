# Commands

## First-Time Setup

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

This is the recommended flow. Do not require users to type `--recurse-submodules`; `setup.ps1` initializes the child repositories after the main repository is cloned.

`setup.ps1` initializes `repos/oceans-skills` and `repos/community-skills`, validates structure, installs skills, and prints next steps.

## About `--recurse-submodules`

This command is valid Git:

```powershell
git clone --recurse-submodules https://github.com/oceans777/skills.git
```

It clones the entry repository and its child repositories in one Git command. In this project, the simpler user-facing flow is preferred:

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

Both approaches can result in all repositories being present locally. The `setup.ps1` flow is easier to remember and also runs validation and installation.

## Daily Usage

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
.\oceans.ps1 validate
.\oceans.ps1 status
```

## Command Reference

`sync` updates the entry repository and checks out child repositories at the versions pinned by the entry repository.

`install` installs skills into the local Codex skills directory.

`validate` checks skill structure, required files, and third-party attribution.

`status` prints repository state, submodule state, and install target state.

`help` prints available commands.
