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
