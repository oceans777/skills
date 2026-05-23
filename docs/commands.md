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
```

### Ubuntu and macOS

```sh
./oceans sync
./oceans install
./oceans validate
./oceans status
```

## Command Reference

`sync` updates the entry repository and checks out child repositories at the versions pinned by the entry repository.

`install` installs skills into the local Codex skills directory.

`validate` checks skill structure, required files, and third-party attribution.

`status` prints repository state, submodule state, and install target state.

`help` prints available commands.
