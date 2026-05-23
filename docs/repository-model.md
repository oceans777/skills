# Repository Model

The oceans777 skill system uses one entry repository and two skill repositories.

```text
oceans777/skills
oceans777/oceans-skills
oceans777/community-skills
```

Users clone only `oceans777/skills`. The entry repository uses Git submodules to include the two skill repositories under `repos/`.

`oceans777/oceans-skills` contains original or primary-maintained skills.

`oceans777/community-skills` contains third-party skills with upstream attribution and license records.

This keeps synchronization simple for users while keeping ownership boundaries clear.
