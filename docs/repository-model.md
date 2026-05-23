# Repository Model

The oceans777 skill system uses one entry repository and two skill repositories.

```text
oceans777/skills
oceans777/oceans-skills
oceans777/community-skills
```

Users clone only `oceans777/skills`. The entry repository uses Git submodules to include the two skill repositories under `repos/`.

Git submodules are pointers from one repository to another repository at a specific commit. In this system, that means `oceans777/skills` controls exactly which versions of `oceans777/oceans-skills` and `oceans777/community-skills` are installed together.

The recommended setup command is:

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

`setup.ps1` runs `git submodule update --init --recursive`, so the child repositories are cloned during setup. Users do not need to remember `git clone --recurse-submodules`.

`oceans777/oceans-skills` contains original or primary-maintained skills.

`oceans777/community-skills` contains third-party skills with upstream attribution and license records.

This keeps synchronization simple for users while keeping ownership boundaries clear.
