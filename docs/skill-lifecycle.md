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
- `blocked`: stop using the managed runtime copy because of a security, license, or integrity incident.

A lifecycle transition is not considered locally enforced merely because the catalog file changed. `archive` and `block` reconcile all known existing runtime roots before the command returns. `sync` also reconciles lifecycle state after updating the entry repository and child repositories.

The reconciler only moves a directory when it has a valid `.oceans-skill-source` marker from `oceans-skills` or `community-skills`. An unmanaged local directory is never deleted or moved automatically. When an unmanaged directory has the same name as a blocked skill, reconciliation fails closed, prints its exact path, and requires the operator to remove or rename it manually. The catalog remains blocked even when local reconciliation reports this conflict.

## State commands

```sh
./oceans catalog list
./oceans catalog deprecate --skill old-skill --reason "Upstream no longer works" --replacement new-skill
./oceans catalog archive --skill old-skill --reason "Unsupported runtime"
./oceans catalog block --skill unsafe-skill --reason "License or security incident"
./oceans catalog restore --skill old-skill
./oceans catalog unblock --skill unsafe-skill --reason "Incident remediated and reviewed"
```

`restore` is limited to `deprecated` and `archived`. A blocked skill requires the separate `unblock` action and a remediation reason. Restoring or unblocking reinstalls the active published package into existing managed runtime roots. Tests and controlled maintenance may pass an explicit install root; normal commands reconcile every known existing runtime root.

## Add a candidate from GitHub

An administrator may submit a repository, skill directory, or `SKILL.md` URL:

```sh
./oceans add --url https://github.com/owner/repository/tree/main/path/to/skill
```

The intake command:

1. accepts only canonical HTTPS GitHub URLs;
2. rejects percent-encoded or ambiguous path forms;
3. resolves slash-containing branch or tag names by longest matching reference;
4. pins the exact imported commit;
5. clones without running upstream scripts and skips Git LFS smudging;
6. enforces path containment, symlink rejection, strict metadata, secret scanning, file-count budget, and byte budget;
7. preserves a community license and attribution;
8. writes only to the isolated review queue;
9. never activates a candidate in the same command.

The local-repository intake path exists only for isolated regression fixtures and requires the explicit `OCEANS_TEST_MODE=1` environment variable. It is not exposed by the public command wrapper and must not be used as production provenance.

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

## Continuous integration

Every behavioral test runs as an independently named job on its supported operating systems. Failure output is uploaded as a workflow artifact, so a red gate identifies the exact test rather than hiding it inside one aggregated platform job. A release is not acceptable until Ubuntu, macOS, Windows validation, and every behavioral test pass.

## State decisions

Do not archive solely because a repository is old. Archive or deprecate when tests repeatedly fail, the supported runtime is incompatible, upstream is abandoned and broken, a maintained replacement exists, or maintenance intentionally ends. Use `blocked` for urgent security, license, or integrity failures.
