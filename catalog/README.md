# Skill catalog

The catalog is the installation source of truth.

- `skills/<skill-name>.skill` is the only lifecycle record for a skill.
- `status` is one of `active`, `pending-review`, `deprecated`, `archived`, or `blocked`.
- `review-queue/<package-repository>/<skill-name>/` stores a candidate package before approval.
- An update to an active skill stays active while its candidate is reviewed.
- `candidate_content_sha256` binds the reviewed candidate directory to a deterministic package fingerprint.
- Approval recalculates the candidate fingerprint before copying, recalculates the published package after copying, promotes it to `content_sha256`, and clears all candidate fields atomically.
- Rejection removes only the candidate; it does not disturb the current active package or its content fingerprint.
- `archived` and `blocked` packages remain in Git history and are disabled from managed runtime roots during reconciliation.

Records use strict UTF-8 `key=value` schema version 2. The original lifecycle fields remain required. `content_sha256` and `candidate_content_sha256` are backward-compatible integrity fields: legacy records without them remain readable, while every newly queued candidate must include a valid lowercase SHA-256 value. Unknown, malformed, duplicate, or missing required fields fail validation.
