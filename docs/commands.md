# Commands

## First-Time Setup

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

`setup.ps1` initializes submodules, validates structure, installs skills, and prints next steps.

## Daily Usage

```powershell
.\oceans.ps1 sync
.\oceans.ps1 install
.\oceans.ps1 validate
.\oceans.ps1 status
```

## Command Reference

`sync` updates the entry repository and checks out submodules at the versions pinned by the entry repository.

`install` installs skills into the local Codex skills directory.

`validate` checks skill structure, required files, and third-party attribution.

`status` prints repository state, submodule state, and install target state.

`help` prints available commands.
