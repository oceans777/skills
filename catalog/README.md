# Skill catalog

The catalog is the installation source of truth.

- `skills/<skill-name>.skill` is the only lifecycle record for a skill.
- `status` is one of `active`, `pending-review`, `deprecated`, `archived`, or `blocked`.
- `review-queue/<package-repository>/<skill-name>/` stores a candidate package before approval.
- An update to an active skill stays active while its candidate is reviewed.
- Approval promotes the candidate into the child repository and clears the candidate fields atomically.
- Rejection removes only the candidate; it does not disturb the current active package.
- `archived` and `blocked` packages remain in Git history and are disabled from managed runtime roots during reconciliation.

Records use strict UTF-8 `key=value` schema version 2. Unknown, missing, malformed, or duplicate fields fail validation.
