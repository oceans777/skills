# Skill catalog

The catalog is the installation source of truth. A skill must have exactly one record under one lifecycle directory:

- `active`: installed and updated by default.
- `pending-review`: imported but not installable until approved.
- `deprecated`: retained for existing users but not installed for new users.
- `archived`: retained for history and excluded from installation.
- `blocked`: excluded immediately because of security, license, or integrity concerns.

Each record is a UTF-8 `key=value` file named `<skill-name>.skill`. The directory is the state; do not copy one record into multiple state directories.
