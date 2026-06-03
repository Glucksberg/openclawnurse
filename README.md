# OpenClawNurse

OpenClawNurse is a portable maintenance helper for OpenClaw installations. It runs periodic checks, applies safe local remediations, keeps the gateway healthy, and leaves an auditable state/report trail.

It is designed to be installed next to an OpenClaw runtime and run unattended from `systemd --user` or `cron`.

## Capabilities

- checks whether an OpenClaw update is available
- applies OpenClaw updates through the local CLI
- runs `openclaw doctor` and captures the result
- repairs common local state issues without interactive prompts
- backs up and restores `openclaw.json` when the config is invalid
- deduplicates stale OpenClaw installations that can shadow the active CLI
- removes OpenClaw-related PM2 apps/temporary daemons while preserving unrelated PM2 apps
- repairs local launcher/path drift for common npm/pnpm installs
- checks commitments, security audit output, package drift and local hotfix markers
- restarts the OpenClaw gateway when maintenance requires it
- waits for gateway health after maintenance
- scans runtime, Telegram, config and gateway logs for actionable issues
- writes state, logs and reports under the user's local state directory
- can report directly through Telegram or through an OpenClaw cron alert job

## Install

```bash
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh
```

By default, the installer:

- copies runtime files to `~/.local/share/openclawnurse`
- creates config at `~/.config/openclawnurse/openclawnurse.env`
- writes state and logs to `~/.local/state/openclawnurse`
- installs a `systemd --user` timer, with `cron` fallback
- runs a post-install self-test and dry-run

Useful commands:

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --self-test
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --dry-run
systemctl --user status openclawnurse.timer
journalctl --user -u openclawnurse.service -n 200 --no-pager
```

## Configuration

The main config file is:

```bash
~/.config/openclawnurse/openclawnurse.env
```

Common settings:

- `OPENCLAW_BIN`: OpenClaw CLI path. Defaults to `openclaw`.
- `RUN_PROFILE`: `light` for the normal daily run, or `heavy` for full doctor/security maintenance.
- `openclawnurse-heavy`: installed wrapper/trigger key for agents to request the heavy profile explicitly.
- `AUTO_UPDATE`: whether the Nurse should apply available updates.
- `OPENCLAW_UPDATE_MODE`: `standard` for the default `openclaw update` flow, or `fork_manager` for hosts that run OpenClaw from a fork-manager production branch.
- `FORK_MANAGER_REPO_DIR`: local OpenClaw checkout used when `OPENCLAW_UPDATE_MODE=fork_manager`.
- `FORK_MANAGER_PRODUCTION_BRANCH`: branch to deploy in fork-manager mode, usually `main-with-all-prs`.
- `FORK_MANAGER_SYNC_COMMAND`, `FORK_MANAGER_BUILD_COMMAND`, `FORK_MANAGER_GATEWAY_INSTALL_COMMAND`: optional host policy commands for syncing, building, and installing the fork-manager runtime.
- `AUTO_ALIGN_OPENCLAW_USER_PLUGINS`: whether the Nurse should align user-installed
  `@openclaw/*` packages under `~/.openclaw/npm` with the active OpenClaw runtime
  in standard update mode. Fork-manager mode reports installed plugin versions
  without trying to install matching npm versions for local OpenClaw revisions.
- `OPENCLAW_PLUGIN_ALIGN_PACKAGES`: `auto` to align every `@openclaw/*`
  dependency in `~/.openclaw/npm/package.json`, or a space-separated package list.
- `AUTO_SELF_UPDATE`: whether the Nurse should pull its own git upstream, validate it, install the refreshed runtime scripts, and use the new version on the next run.
- `SELF_UPDATE_REPO_DIR`: local OpenClawNurse git checkout used for self-update. The installer writes this automatically.
- `SELF_UPDATE_POLICY`: `reset-to-remote` for aggressive upstream convergence with a clean-worktree guard, or `fast-forward` for stricter history preservation.
- The systemd unit constrains Nurse runs with memory/swap/CPU limits so a stuck OpenClaw maintenance command is killed with the service instead of exhausting the host.
- `RESTART_MODE`: gateway restart strategy, usually `systemd_user`.
- `SYSTEMD_UNIT_NAME`: gateway service name, usually `openclaw-gateway.service`.
- `REPORT_CHANNEL`: report channel, for example `telegram` or `none`.
- `TELEGRAM_TARGET`: chat/group id for direct reports.
- `TELEGRAM_BOT_TOKEN`: optional dedicated token. If empty, the Nurse can reuse the OpenClaw Telegram token from `~/.openclaw/openclaw.json`.
- `EXPECTED_OPENCLAW_MODEL`: optional expected primary model. If unset, the Nurse can infer `openai-codex/*` when the host has Codex OAuth but no direct OpenAI API key.
- `AUTO_REMEDIATE_EXPECTED_OPENCLAW_MODEL`: restores model config drift after `openclaw doctor --repair`.
- `AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD`: removes PM2 apps whose name or metadata points to OpenClaw and keeps the gateway under systemd.
- `AUTO_CLEAN_OPENCLAW_PM2_DAEMONS`: stops OpenClaw/OpenClawNurse-related PM2 daemon processes left outside the normal PM2 home.
- `SECURITY_AUDIT_ACCEPTED_WARNINGS`: space-separated security audit warning IDs that are accepted for this host's explicit trust model.
- `ENABLE_COMMITMENTS_SANITY`: checks enabled commitments and recent extractor traces for model/provider errors.
- `ENABLE_SECURITY_AUDIT`: runs `openclaw security audit --json` and promotes critical findings to failed status.
- `ENABLE_PACKAGE_DRIFT_SANITY`: detects local package hotfix markers that could be overwritten by future updates.
- `EXTRA_PATH`: extra executable paths for environments such as Linuxbrew or custom package managers.

See `config/openclaw-doctor.env.example` for the complete set of runtime options.

## Alerts

OpenClawNurse can deliver reports directly through Telegram, or it can write local state and let OpenClaw send alerts from its own configured bot/channel.

For OpenClaw-managed alerts, run the installer with:

```bash
./install.sh \
  --configure-openclaw-alert \
  --openclaw-alert-target "-1001234567890" \
  --openclaw-alert-agent "main" \
  --openclaw-alert-every "12h"
```

The alert helper reads `doctor-state.json` and sends only relevant incident or recovery messages.

## Sanity Probes

The extra probes are designed to detect issues that `openclaw doctor` may report
indirectly or not report on its own:

- commitments: verifies that enabled commitments can be listed and scans recent
  extractor traces for provider/model errors.
- security audit: runs `openclaw security audit --json`; critical findings mark
  the Nurse run as failed, while warnings become follow-up items.
- package drift: looks for local hotfix markers inside the active OpenClaw
  package so operators know updates may overwrite local repairs.
- user plugin drift: compares user-installed `@openclaw/*` plugins under
  `~/.openclaw/npm` with the active OpenClaw runtime and can align them after
  updates or drift.
- gateway logs: scans recent journal output for provider errors, config issues,
  stuck sessions, and update provenance warnings.

The Nurse only auto-fixes narrow local file permission issues. Sensitive policy
changes such as open groups with elevated tools, insecure Control UI exposure, or
channel scope changes remain manual follow-up.

## Runtime Behavior

OpenClawNurse is not a long-running daemon. It runs as a scheduled job, performs one maintenance pass, writes state, and exits.

During a live run it can:

- create a config backup
- update OpenClaw
- deploy a configured fork-manager production branch instead of running `openclaw update`
- align user-installed `@openclaw/*` plugins with the updated runtime
- run doctor repair
- quarantine stale OpenClaw paths under `~/.local/state/openclawnurse/quarantine/`
- clean missing or orphaned session transcript references
- refresh or restart the gateway service
- verify health after restart

Quarantine is used instead of deletion so that changes remain reversible.

## Repository Layout

- `install.sh`: top-level installer entrypoint
- `scripts/install-doctor.sh`: idempotent installer implementation
- `scripts/openclaw-doctor.sh`: main runtime
- `scripts/openclawnurse-openclaw-alert.sh`: OpenClaw cron alert helper
- `systemd/`: `systemd --user` service/timer templates
- `config/openclaw-doctor.env.example`: example config
- `docs/`: setup and operator notes
- `legacy/openclawnurse-fleet-multihost-legacy-2026-05-05.tar.gz`: archived fleet/multihost experiment, not part of the active program

## Validation

Before publishing changes, run:

```bash
bash -n install.sh
for script in scripts/*.sh; do bash -n "$script"; done
find config -name '*.json' -print0 | xargs -0 -r -n1 jq empty
scripts/test-smoke.sh
```

The GitHub Actions workflow runs the same validation. `shellcheck` is run as a non-blocking warning check.

## Legacy

Older fleet and multihost experiments are preserved as `legacy/openclawnurse-fleet-multihost-legacy-2026-05-05.tar.gz` for reference. They are no longer installed, scheduled, tested or described as part of OpenClawNurse's main runtime.
