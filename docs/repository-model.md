# Repository Model

The oceans777 skill system has one entry repository, one community package, and one repository per first-party skill.

```text
oceans777/skills
oceans777/community-skills
oceans777/<skill-id>
```

Users clone only `oceans777/skills`. The entry repository uses Git submodules under `repos/`.

- `repos/community-skills` is the third-party skill repository, with upstream attribution and license records. Its catalog records use `package_repository=community-skills`.
- `repos/<skill-id>` is the canonical first-party skill. The repository root is the skill package, for example `repos/prd-skill` → `https://github.com/oceans777/prd-skill`. Managed install reads that directory. The catalog field `package_repository` is the skill id.
- `prd-blueprint` and `git-upstream-sync-guard` are archived catalog-only names. They point at `prd-skill` and `fork-skill` and have no package directory.
- `oceans777/oceans-skills` is retired. It is not a submodule and is not required to install or validate first-party skills. Existing install markers that still say `source_repository=oceans-skills` remain managed and update from the skill repository.

Git submodules are pointers from one repository to another repository at a specific commit. The entry repository controls which commits are installed together.

The recommended setup command is:

```powershell
git clone https://github.com/oceans777/skills.git
cd skills
.\setup.ps1
```

`setup.ps1` runs `git submodule update --init --recursive`, so the child repositories are cloned during setup. Users do not need to remember `git clone --recurse-submodules`.

One-line installs in the README point at `https://github.com/oceans777/<skill-id>`. That path is for installing a single skill into the current project. It does not replace the managed catalog, content fingerprint, or lifecycle commands.

Do not reintroduce an aggregate named `oceans-skills`. The entry repository already uses the name `skills`.
