# Repository Model

The oceans777 skill system has one entry repository, one community repository, one first-party aggregate, and one repository per first-party skill.

```text
oceans777/skills
oceans777/community-skills
oceans777/oceans-skills
oceans777/<skill-id>
```

Users clone only `oceans777/skills`. The entry repository uses Git submodules under `repos/`.

- `repos/community-skills` is the third-party skill repository, with upstream attribution and license records.
- `repos/oceans-skills` is the first-party compatibility aggregate. Managed install reads published packages from `repos/oceans-skills/skills/<skill-id>` because catalog records still use `package_repository=oceans-skills` or `package_repository=community-skills`.
- `repos/<skill-id>` pins the canonical skill repository, for example `repos/fork-skill` → `https://github.com/oceans777/fork-skill`. Inside the aggregate, `skills/<skill-id>` is usually a submodule of that same repository. `skills/git-upstream-sync-guard` is only a deprecation stub.

Git submodules are pointers from one repository to another repository at a specific commit. The entry repository controls which commits are installed together.

The recommended setup command is:

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

`setup.ps1` runs `git submodule update --init --recursive`, so the child repositories are cloned during setup. Users do not need to remember `git clone --recurse-submodules`.

One-line installs in the README point at `https://github.com/oceans777/<skill-id>`. That path is for installing a single skill into the current project. It does not replace the managed catalog, content fingerprint, or lifecycle commands.

Do not rename `oceans-skills` to `skills`. The entry repository already uses that name.
