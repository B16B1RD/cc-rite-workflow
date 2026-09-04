# Wiki Promotion Audit — Inline Content Delegation

The `promote: rite-plugin` page
`inline-content-delegation-avoids-malformed-toolcall` is shelved because
the plugin already enforces the pattern mechanically at both production and
detection points.

| Wiki page | Decision | Enforcement pointer |
|---|---|---|
| `inline-content-delegation-avoids-malformed-toolcall` | shelve — already mechanized | `pr-create/SKILL.md` Phase 3.4 three-stage protocol, `bash-heaviness-check.sh`'s `inline-gh-create-title` signal, and `pr-cycle-cleanup.sh` orphan-workdir reaper |

## Existing mechanical contract

`pr-create/SKILL.md` requires a three-stage protocol: allocate a dedicated
workdir, write title and body as raw files, then pass the title through a shell
variable and the body through `--body-file`. Empty title/body guards and
signal-specific cleanup traps make the delivery path fail loudly and cleanly.

`bash-heaviness-check.sh` rejects literal `--title` arguments in
`gh pr create` and `gh issue create`, including backslash-continued command
forms. This prevents future command specifications from reintroducing the
inline-title trigger.

The protocol spans multiple tool processes, so an interruption between workdir
allocation and the final shell call cannot be handled by that call's traps.
`pr-cycle-cleanup.sh` closes this lifecycle gap by reaping
`rite-pr-create-*` directories only after a 24-hour age guard.

No follow-up is needed: Cause B (inline title/body content) is prevented by the
producer contract and lint signal, while the distinct transport-level Cause A
is explicitly scoped out and its only durable residue is covered by the aged
orphan reaper.
