# Setup Rapido: Node da Fleet

Use este bloco em cada VPS que precisa aparecer no dashboard central.

## 1. Baixar e instalar

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh
```

## 2. Configurar o nurse e o feed do node

Edite `~/.config/openclawnurse/openclawnurse.env` e deixe algo assim:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
REPORT_CHANNEL="telegram"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
AUTO_REMEDIATE_MISSING_TRANSCRIPTS="true"
AUTO_REMEDIATE_ORPHAN_TRANSCRIPTS="true"
AUTO_REMEDIATE_ALL_AGENTS="false"
RESTART_MODE="custom"
RESTART_COMMAND="pm2 restart openclaw-gateway"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"

FLEET_EXPORT_ENABLED="true"
FLEET_EXPORT_NODE_ID="vps-sp-1"
FLEET_EXPORT_NODE_NAME="Sao Paulo VPS"
FLEET_EXPORT_PUBLIC_URL="https://vps-sp-1.example.com"
FLEET_EXPORT_OUTPUT="$HOME/.local/state/openclawnurse/fleet/node-feed.json"
FLEET_EXPORT_INCLUDE_STATUS="true"
FLEET_EXPORT_STATUS_TIMEOUT="10"
FLEET_EXPORT_ON_CALENDAR="*-*-* *:00/5:00"
```

Troque estes campos:

- `TELEGRAM_TARGET`
- `FLEET_EXPORT_NODE_ID`
- `FLEET_EXPORT_NODE_NAME`
- `FLEET_EXPORT_PUBLIC_URL`

## 3. Reaplicar a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh
```

## 4. Testar

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --self-test \
  --no-notify

~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --dry-run \
  --no-notify

~/.local/share/openclawnurse/bin/openclaw-fleet-export-run.sh \
  --config ~/.config/openclawnurse/openclawnurse.env

jq . ~/.local/state/openclawnurse/fleet/node-feed.json
```

## 5. Conferir timers

```bash
systemctl --user status openclawnurse.timer --no-pager
systemctl --user status openclaw-fleet-export.timer --no-pager
```

## 6. Entregar o feed para o host central

O arquivo que interessa e:

```bash
~/.local/state/openclawnurse/fleet/node-feed.json
```

Expose isso por HTTP ou sincronize para o host central.
