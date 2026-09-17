# shellcheck shell=bash
# Clears ambient runtime identity and state-root inputs so hook tests see only
# what each fixture sets. Tests also run from live Claude, Codex, and Grok
# dogfooding sessions, and an inherited session ID, RITE_HOST, or state root
# diverts sandbox operations to a foreign owner or makes identity resolution fail.
#
# run-tests.sh and _test-helpers.sh source this file; tests that read ambient
# identity without _test-helpers.sh source it themselves. The name does not end
# in `.test.sh`, so run-tests.sh never runs it as a test.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST CLAUDE_PLUGIN_ROOT
unset CLAUDE_ENV_FILE RITE_STATE_ROOT RITE_RUNTIME_EXPLICIT _RITE_HOOK_REDIRECTED
