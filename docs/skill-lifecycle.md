# Skill lifecycle and URL intake

## First principle

A published package, a review candidate, a lifecycle decision, and a runtime copy are different facts. They must not overwrite or silently contradict one another.

- Child repositories contain the currently published packages.
- `catalog/skills/<name>.skill` is the only lifecycle record for each skill.
- `catalog/review-queue/<package-repository>/<name>/` contains an isolated candidate.
- An active skill remains active while an update candidate is reviewed.
- Approval promotes the candidate into the child repository and updates its provenance and content fingerprint.
- A runtime copy is accepted only after it matches the published content fingerprint.
- Rejection removes only the candidate and preserves the current package.

## Lifecycle states

- `active`: install and update the published package.
- `pending-review`: a new skill has only a candidate and is not installable.
- `deprecated`: retain existing managed copies, but do not install or update for new users.
- `archived`: stop using the managed runtime copy and preserve it under `.oceans-disabled`.
- `blocked`: stop using the managed runtime copy because of a security, license, or integrity incident.

A lifecycle transition is not considered locally enforced merely because the catalog file changed. `archive` and `block` reconcile all known existing runtime roots before the command returns. `sync` also reconciles lifecycle state after updating the entry repository and child repositories.

The reconciler only moves a directory when it has a valid `.oceans-skill-source` marker from `oceans-skills` or `community-skills`. An unmanaged local directory is never deleted or moved automatically. When an unmanaged directory has the same name as a blocked skill, reconciliation fails closed, prints its exact path, and requires the operator to remove or rename it manually. The catalog remains blocked even when local reconciliation reports this conflict.

## Runtime enforcement boundary

Runtime lifecycle enforcement is deliberately separated from ordinary installation validation:

1. a lifecycle command writes and locks the target skill record;
2. emergency reconciliation reads only the target skill state instead of depending on unrelated catalog records or packages;
3. every known runtime root is attempted even when an earlier root reports a conflict;
4. managed copies that can be disabled are preserved under `.oceans-disabled`;
5. all conflicts are aggregated and the command returns failure only after every root was attempted.

Runtime roots are persisted outside the skill packages. Normal platform roots and explicit custom install roots are merged into one registry. The default registry is stored under the operating system state directory and may be overridden in controlled environments with `OCEANS_RUNTIME_ROOTS_FILE`. A directory-internal marker is supporting evidence; it is not the only way a runtime root is discovered.

A lifecycle transition changes files on disk. A runtime that already loaded a skill into memory may still require a restart or reload before the active process stops using it. Disk reconciliation and in-memory invalidation are separate facts and must not be reported as the same result.

## State commands

```sh
./oceans catalog list
./oceans catalog deprecate --skill old-skill --reason "Upstream no longer works" --replacement new-skill
./oceans catalog archive --skill old-skill --reason "Unsupported runtime"
./oceans catalog block --skill unsafe-skill --reason "License or security incident"
./oceans catalog restore --skill old-skill
./oceans catalog unblock --skill unsafe-skill --reason "Incident remediated and reviewed"
```

`restore` is limited to `deprecated` and `archived`. A blocked skill requires the separate `unblock` action and a remediation reason. Restoring or unblocking reinstalls the active published package into every known existing runtime root. Tests and controlled maintenance may pass an explicit install root; every successful explicit installation also registers that root for later reconciliation.

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
8. builds a deterministic SHA-256 fingerprint from sorted UTF-8 path bytes and each included file hash;
9. stores that fingerprint in `candidate_content_sha256` beside the candidate provenance;
10. writes only to the isolated review queue;
11. never activates a candidate in the same command.

The local-repository intake path exists only for isolated regression fixtures and requires the explicit `OCEANS_TEST_MODE=1` environment variable. It is not exposed by the public command wrapper and must not be used as production provenance.

## Approval integrity boundary

Approval does not trust the review directory merely because it exists. The activation command:

1. validates metadata, paths, links, risk rules, and attribution;
2. normalizes package permissions so directories remain traversable and package files are non-executable;
3. recalculates the review-directory fingerprint and compares it with `candidate_content_sha256`;
4. copies through a sibling staging directory;
5. recalculates the staged package before activation;
6. recalculates the published child-repository directory after activation;
7. promotes the verified value to `content_sha256` and clears the candidate fields.

Any difference means the candidate changed after intake and activation fails closed. The original published package and candidate review directory are restored.

## Runtime installation integrity boundary

Installation does not trust the published directory merely because repository validation previously succeeded. For every active package, the installer:

1. recalculates the published source directory and compares it with `content_sha256`;
2. copies into a sibling staging directory;
3. removes excluded metadata and normalizes permissions;
4. recalculates the staging directory and compares it with the verified source value;
5. atomically replaces the runtime directory;
6. recalculates the final runtime directory while excluding the local management marker;
7. restores the previous runtime copy when the final value differs.

The `.oceans-skill-source` marker records the skill name, repository, install root, runtime, catalog timestamp, and verified content fingerprint. Marker data is cross-checked before a runtime directory is treated as managed.

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

Every behavioral test runs as an independently named job on its supported operating systems. Failure output is uploaded as a workflow artifact, so a red gate identifies the exact test rather than hiding it inside one aggregated platform job. The workflow uses explicit read-only permissions, immutable action revisions, disabled credential persistence, and job timeouts. A release is not acceptable until Ubuntu, macOS, Windows validation, and every behavioral test pass.

The runtime reconciliation suite covers persisted custom roots, partial multi-root failure, targeted emergency block despite unrelated catalog corruption, source-package tampering, runtime fingerprint verification, rollback, and canonical executable permissions.

## State decisions

Do not archive solely because a repository is old. Archive or deprecate when tests repeatedly fail, the supported runtime is incompatible, upstream is abandoned and broken, a maintained replacement exists, or maintenance intentionally ends. Use `blocked` for urgent security, license, or integrity failures.
