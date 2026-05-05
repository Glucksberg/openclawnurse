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
- repairs local launcher/path drift for common npm/pnpm installs
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
- `AUTO_UPDATE`: whether the Nurse should apply available updates.
- `RESTART_MODE`: gateway restart strategy, usually `systemd_user`.
- `SYSTEMD_UNIT_NAME`: gateway service name, usually `openclaw-gateway.service`.
- `REPORT_CHANNEL`: report channel, for example `telegram` or `none`.
- `TELEGRAM_TARGET`: chat/group id for direct reports.
- `TELEGRAM_BOT_TOKEN`: optional dedicated token. If empty, the Nurse can reuse the OpenClaw Telegram token from `~/.openclaw/openclaw.json`.
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

## Runtime Behavior

OpenClawNurse is not a long-running daemon. It runs as a scheduled job, performs one maintenance pass, writes state, and exits.

During a live run it can:

- create a config backup
- update OpenClaw
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
