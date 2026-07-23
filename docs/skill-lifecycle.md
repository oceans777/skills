# Skill lifecycle and URL intake

## First principle

A published package, a review candidate, and a lifecycle decision are different facts. They must not overwrite one another.

- Child repositories contain the currently published packages.
- `catalog/skills/<name>.skill` is the only lifecycle record for each skill.
- `catalog/review-queue/<package-repository>/<name>/` contains an isolated candidate.
- An active skill remains active while an update candidate is reviewed.
- Approval promotes the candidate into the child repository and updates its provenance.
- Rejection removes only the candidate and preserves the current package.

## Lifecycle states

- `active`: install and update the published package.
- `pending-review`: a new skill has only a candidate and is not installable.
- `deprecated`: retain existing managed copies, but do not install or update for new users.
- `archived`: stop using the managed runtime copy and preserve it under `.oceans-disabled`.
- `blocked`: immediately stop using the managed runtime copy because of a security, license, or integrity incident.

The installer never moves an unmanaged local skill. Only directories with a valid `.oceans-skill-source` marker from `oceans-skills` or `community-skills` are reconciled.

## State commands

```sh
./oceans catalog list
./oceans catalog deprecate --skill old-skill --reason "Upstream no longer works" --replacement new-skill
./oceans catalog archive --skill old-skill --reason "Unsupported runtime"
./oceans catalog block --skill unsafe-skill --reason "License or security incident"
./oceans catalog restore --skill old-skill
./oceans catalog unblock --skill unsafe-skill --reason "Incident remediated and reviewed"
```

`restore` is limited to `deprecated` and `archived`. A blocked skill requires the separate `unblock` action and a remediation reason.

## Add a candidate from GitHub

An administrator may submit a repository, skill directory, or `SKILL.md` URL:

```sh
./oceans add --url https://github.com/owner/repository/tree/main/path/to/skill
```

The intake command:

1. accepts only HTTPS GitHub URLs;
2. resolves slash-containing branch or tag names by longest matching reference;
3. pins the exact imported commit;
4. clones without running upstream scripts and skips Git LFS smudging;
5. enforces path containment, symlink rejection, strict metadata, secret scanning, file-count budget, and byte budget;
6. preserves a community license and attribution;
7. writes only to the isolated review queue;
8. never activates a candidate in the same command.

Review and approve:

```sh
./oceans validate
./oceans catalog activate --skill skill-name
./oceans validate
./oceans publish
```

Reject a candidate:

```sh
./oceans catalog reject --skill skill-name
```

For an existing active skill, queue a newer candidate without interrupting the current package:

```sh
./oceans add \
  --url https://github.com/owner/repository/tree/release/v2/path/to/skill \
  --replace-existing
```

Changing the upstream repository requires the additional `--allow-source-change` flag after a provenance review. Cross-package-repository migration remains blocked.

## Publication order

Publishing cannot be physically atomic across three Git repositories. The implementation therefore makes the user-visible entry repository the commit point:

1. validate child worktrees and the catalog;
2. prepare child commits locally;
3. create one entry commit containing both submodule pointers and catalog changes;
4. push child commits;
5. push the entry commit last.

If the final entry push fails, child commits may exist as unreferenced commits, but users remain on the previous coherent entry commit. Re-running `publish` completes the prepared release.

## State decisions

Do not archive solely because a repository is old. Archive or deprecate when tests repeatedly fail, the supported runtime is incompatible, upstream is abandoned and broken, a maintained replacement exists, or maintenance intentionally ends. Use `blocked` for urgent security, license, or integrity failures.
