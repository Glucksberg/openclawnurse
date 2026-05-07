# AGENTS.md - OpenClawNurse

This folder is home. Treat it that way.

## Working Style

Before making changes, read enough of the local project to understand its shape.
State assumptions explicitly when they matter, and surface ambiguity instead of
silently choosing a risky interpretation.

Don't ask permission for normal local exploration or implementation work. Ask
first before destructive actions, public posts, messages sent externally, or
anything that could expose private data.

## Memory

Use `memory/YYYY-MM-DD.md` for lightweight project notes when the directory
exists. Capture decisions, important project state, installed tools, and mistakes
worth avoiding later. Do not store secrets unless explicitly asked.

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- `trash` > `rm` when removing local files.
- Treat Telegram tokens, OpenClaw credentials, local config, and host reports as
  sensitive.
- Be conservative with scripts that modify `systemd`, `crontab`, PM2, gateway
  processes, or installed OpenClaw files.
- When in doubt, ask.

## Coding Discipline

### 1. Think Before Coding

- State assumptions explicitly.
- If multiple interpretations exist, surface them instead of picking one silently.
- Ask clarifying questions when uncertainty matters.
- Push back when a simpler or safer approach is better than the requested path.
- If confused, stop and name what is unclear.

### 2. Simplicity First

- Write the minimum code that solves the problem.
- Do not add speculative abstractions, flexibility, configuration, or features.
- Do not build for imaginary future requirements.
- If a 200-line solution can be 50 lines without losing correctness, simplify it.

### 3. Surgical Changes

- Touch only what is required for the task.
- Do not refactor or clean up unrelated code unless asked.
- Match the existing local style, even if you would normally do it differently.
- Remove only the dead code created by your own changes.
- If you spot unrelated issues, mention them separately instead of changing them opportunistically.

### 4. Goal-Driven Execution

- Turn vague instructions into verifiable success criteria.
- Prefer checks, tests, or observable outcomes over "it should work now".
- For multi-step work, state a short plan with a verification step for each part.
- Keep iterating until the result is verified or the blocker is explicit.

## External vs Internal

Safe to do freely:
- Read files, explore, organize, learn.
- Search the web when current or source-backed information is needed.
- Work within this workspace.

Ask first:
- Sending emails, tweets, public posts, or chat messages.
- Anything that leaves the machine on behalf of the user.
- Anything you're uncertain about.

## Tools

Skills provide specialized workflows. When a task clearly matches an available
skill, read that skill's `SKILL.md` and follow it.

Use `rtk` for verbose shell commands when practical, especially git, package
managers, builds, tests, search, and directory listings.

## Project Notes

- Portable OpenClaw maintenance utility, mostly shell scripts and config
  templates.
- Main files: `scripts/openclaw-doctor.sh`, `scripts/install-doctor.sh`,
  `install.sh`, `config/openclaw-doctor.env.example`, `systemd/`, and `docs/`.
- Local validation: `bash -n install.sh`,
  `for script in scripts/*.sh; do bash -n "$script"; done`,
  `jq empty config/*.json`, and `scripts/test-smoke.sh`.
- This repo intentionally avoids a long-running PM2 daemon; it is designed for
  `systemd --user` timer or cron execution.

