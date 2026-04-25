# Setup Rapido: Host Central com Uptime Kuma

Use este bloco se voce quer o dashboard central e tambem push monitor para o Uptime Kuma.

## 1. Baixar e instalar

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh --skip-dry-run
```

## 2. Criar o arquivo de nodes com URLs do Kuma

Crie `~/.config/openclawnurse/fleet-nodes.json`:

```json
{
  "fleetName": "Minha Fleet OpenClaw",
  "overallKumaPushUrl": "https://kuma.example.com/api/push/GERAL?token=TOKEN_GERAL",
  "nodes": [
    {
      "id": "vps-sp-1",
      "name": "Sao Paulo VPS",
      "feedUrl": "https://vps-sp-1.example.com/openclawnurse/node-feed.json",
      "dashboardUrl": "https://vps-sp-1.example.com",
      "kumaPushUrl": "https://kuma.example.com/api/push/SP1?token=TOKEN_SP1",
      "tags": ["prod", "telegram"]
    },
    {
      "id": "vps-us-1",
      "name": "US VPS",
      "feedUrl": "https://vps-us-1.example.com/openclawnurse/node-feed.json",
      "dashboardUrl": "https://vps-us-1.example.com",
      "kumaPushUrl": "https://kuma.example.com/api/push/US1?token=TOKEN_US1",
      "tags": ["prod", "whatsapp"]
    }
  ]
}
```

## 3. Configurar o host central

Edite `~/.config/openclawnurse/openclawnurse.env`:

```bash
REPORT_CHANNEL="telegram"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"

FLEET_DASHBOARD_ENABLED="true"
FLEET_DASHBOARD_CONFIG_FILE="$HOME/.config/openclawnurse/fleet-nodes.json"
FLEET_DASHBOARD_OUTPUT_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard"
FLEET_DASHBOARD_PUBLISH_DIR="/srv/www/openclaw-fleet"
FLEET_DASHBOARD_HISTORY_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard-history"
FLEET_DASHBOARD_PUSH_KUMA="true"
FLEET_DASHBOARD_ON_CALENDAR="*-*-* *:02/5:00"
```

## 4. Reaplicar a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh --skip-dry-run
```

## 5. Testar agregacao e push do Kuma

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard-run.sh \
  --config ~/.config/openclawnurse/openclawnurse.env

jq . ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json
```

Se o `fleet-nodes.json` estiver com as URLs corretas, o agregador ja faz o push para:

- estado geral da fleet
- estado individual de cada node

## 6. Conferir timer

```bash
systemctl --user status openclaw-fleet-dashboard.timer --no-pager
```

## 7. Publicar o dashboard

Arquivos finais:

```bash
/srv/www/openclaw-fleet/index.html
/srv/www/openclaw-fleet/fleet-status.json
```

## 8. Gerar plano de remediacao

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-remediation-plan.sh \
  --fleet-status ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json \
  --policy ~/.local/share/openclawnurse/config-examples/fleet-remediation-policy.example.json \
  --output ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.json \
  --markdown ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.md
```
