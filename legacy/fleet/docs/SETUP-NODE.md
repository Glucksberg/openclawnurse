# Planejamento Futuro: Setup Rapido de Node da Fleet

Conteudo preservado do fluxo antigo de fleet.

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
AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="true"
PM2_GATEWAY_APP_NAMES="openclaw-gateway openclaw"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
RESTART_COMMAND=""
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
