# Agent notes

- Keep shell operations portable across both macOS and Linux.
  Prefer POSIX-compatible commands and account for BSD/GNU option
  differences, such as `stat -f %g` on macOS versus `stat -c %g` on
  Linux, and `shasum -a 256` versus `sha256sum`.

- Concision is valued. Avoid verbose JSDoc, redundant abstractions, and
  duplicated patterns. Extract helpers when a pattern repeats 3+ times,
  but inline one-off logic.

- **Hostbridge has no reverse dependency on contagent.** It may be split
  into a separate project. Do not add references to contagent in hostbridge
  files (`hostbridge.js`, `hostbridge-client.js`, `hostbridge.md`).
  See [hostbridge.md](hostbridge.md) for protocol and configuration details.

## Commit attribution of AI assistance

AI-assisted commits get an `Assisted-by: AGENT:MODEL [TOOL]...`
trailer (e.g. `Assisted-by: pi:claude-fable-5`), listing specialized
analysis tools if used but not basic dev tools. Do not add
`Co-Authored-By:` or `Signed-off-by:` for AI. Humans own the code
changes and are the only ones that can certify origin. This is derived
from the Linux kernel AI policy (https://docs.kernel.org/process/coding-assistants.html).

Resolve current MODEL from the harness, never from memory or startup
context. Bare model ID only. If resolution fails, ask the operator.

### pi

AGENT is `pi`. Current MODEL comes from `PI_MODEL` in the tool-call environment.

### Claude Code

AGENT is `claude-code`. Current MODEL comes from the session transcript:

    f=$(ls -t ~/.claude/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl | head -1)
    jq -r 'select(.type=="assistant" and (.isSidechain|not)) | .message.model' "$f" | tail -1

### Codex

AGENT is `codex`. Current MODEL comes from the session transcript:

    f=$(find ~/.codex/sessions -type f -name "*${CODEX_SESSION_ID}.jsonl" -print -quit)
    jq -sr '[.[] | select(.type == "turn_context") | .payload.model] | last' "$f"

### OpenCode

AGENT is `opencode` when `OPENCODE=1` is present in the tool-call
environment. Current MODEL comes from OpenCode's session DB by reading
the currently unfinished assistant message:

    opencode db "select data->>'$.modelID' from message where data->>'$.role'='assistant'and data->>'$.finish' is null"|tail -1

### Other agents/harnesses

If you can determine MODEL easily from the environment of a tool call
then do that, otherwise ask the operator.
