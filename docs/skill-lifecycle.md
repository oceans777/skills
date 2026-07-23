# Skill lifecycle and URL intake

## Principle

The child repositories preserve skill files. The entry repository catalog decides whether a skill is installable. Archiving changes state; it does not delete history or silently remove a user's local copy.

## Lifecycle commands

```sh
./oceans catalog list
./oceans catalog deprecate --skill old-skill --reason "Upstream no longer works" --replacement new-skill
./oceans catalog archive --skill old-skill --reason "Unsupported runtime"
./oceans catalog block --skill unsafe-skill --reason "License or security incident"
./oceans catalog restore --skill old-skill
```

PowerShell uses the same model:

```powershell
.\oceans.ps1 catalog -Action archive -Skill old-skill -Reason "Unsupported runtime"
.\oceans.ps1 catalog -Action restore -Skill old-skill
```

Only `active` skills are installed. The installer reports every skipped state and never deletes a local skill automatically.

## Add a skill from GitHub

An administrator can submit a repository, skill directory, or `SKILL.md` URL:

```sh
./oceans add --url https://github.com/owner/repository/tree/main/path/to/skill
```

The intake command:

1. accepts only HTTPS GitHub URLs;
2. clones without executing upstream code;
3. resolves exactly one `SKILL.md`;
4. records the exact imported commit;
5. preserves or requires a license for community skills;
6. generates attribution and packaging notes when absent;
7. runs the existing metadata, path, secret, binary, and symlink checks;
8. stages the skill and registers it as `pending-review`.

After reviewing the staged files:

```sh
./oceans catalog activate --skill skill-name
./oceans validate
./oceans publish
```

Use `--activate` only when the administrator intentionally wants the imported skill immediately eligible for installation. A URL is an intake request, not a security bypass.

## State decisions

Do not archive solely because a repository is old. Archive or deprecate when tests fail repeatedly, the runtime is incompatible, the upstream is abandoned and broken, a maintained replacement exists, or the administrator ends support. Use `blocked` for urgent security, license, or integrity failures.
