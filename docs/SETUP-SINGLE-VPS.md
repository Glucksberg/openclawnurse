# Setup Rapido: VPS Isolada

Use este guia quando a VPS vai operar sozinha, sem fleet e sem host central.

## 1. Baixar e instalar

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh
```

Se `systemd --user` nao funcionar:

```bash
./install.sh --scheduler cron
```

## 2. Configurar a VPS

Edite `~/.config/openclawnurse/openclawnurse.env`:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
REPORT_CHANNEL="telegram"
AUTO_DETECT_TELEGRAM_TARGET="true"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
AUTO_REMEDIATE_MISSING_TRANSCRIPTS="true"
AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS="true"
AUTO_REMEDIATE_ALL_AGENTS="false"
AUTO_RESTART_UNHEALTHY_GATEWAY="true"
MAX_GATEWAY_RESTARTS_PER_DAY="1"
MAX_GATEWAY_RESTARTS_PER_WINDOW="3"
GATEWAY_RESTART_WINDOW_SECONDS="300"
MAX_ORPHAN_TRANSCRIPTS_PER_RUN="20"
CONFIG_BACKUP_ENABLED="true"
CONFIG_BACKUP_RETENTION="20"
AUTO_RESTORE_BROKEN_CONFIG="true"
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="true"
PM2_GATEWAY_APP_NAME="openclaw-gateway"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
RESTART_COMMAND=""
NODE_COMPILE_CACHE="/var/tmp/openclaw-compile-cache"
OPENCLAW_NO_RESPAWN="1"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"
```

Troque:

- `TELEGRAM_TARGET`
- `RESTART_MODE` e `SYSTEMD_UNIT_NAME` somente se o host usar outro supervisor; o recomendado e systemd user

## 3. Reaplicar a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh
```

## 4. Validar

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --self-test \
  --no-notify

~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --dry-run \
  --no-notify

systemctl --user status openclawnurse.timer --no-pager
jq . ~/.local/state/openclawnurse/doctor-state.json
```

## 5. Resultado esperado

Voce quer ver:

- `openclawnurse.timer` ativo
- `self-test` em `OK`
- `doctor-state.json` sendo atualizado
- o grupo do Telegram correto recebendo o report daquela VPS
