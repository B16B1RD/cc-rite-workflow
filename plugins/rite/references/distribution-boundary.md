# Plugin distribution boundary

Everything under `plugins/rite` is a portable distribution artifact, except test fixtures under `hooks/tests` and `scripts/tests`.

Symbolic links are prohibited in that boundary. Packaging and installation may preserve, dereference, or discard links differently, and absolute or relative targets can bind the plugin to one checkout or machine. Store distributable content as regular tracked files instead.

`scripts/tests/distribution-boundary-promotion-contract.test.sh` enforces this policy and also scans regular Markdown, shell, Python, and JSON files for environment-specific tokens. Test fixture directories remain excluded from both checks.
