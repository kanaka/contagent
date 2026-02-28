# contagent

Contagent is a containerized execution environment for coding agents focused on safe autonomy on a developer machine.

It is designed for a common problem: permission prompts are tedious, but running an agent with broad host access can be risky on a primary or sensitive machine. Contagent gives agents a practical sandbox so you can run with fewer interruptions while reducing blast radius.

## Why this is useful

- Permission-heavy sessions become usable: you can run in YOLO mode (`--dangerously-skip-permissions`) without giving the agent your whole machine.
- The agent stays focused on the current project directory instead of broad host filesystem access.
- You keep practical workflows (interactive shell, SSH agent forwarding, Docker-based build/test loops).

## What contagent does

- Installs core CLI tooling plus agent CLIs for Claude Code and OpenCode.
- Launches into the current project path at the same absolute path inside the container.
- Mounts only the project directory and a minimal set of agent-related config/history/auth paths from `$HOME`.
- Runs container processes as your mapped host user (UID/GID), not as root.
- Forwards SSH agent and Docker socket when available.
