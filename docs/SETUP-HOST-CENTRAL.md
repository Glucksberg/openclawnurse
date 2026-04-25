# Setup Rapido: Host Central

Use este bloco em um servidor separado que vai agregar todos os nodes e publicar o dashboard.

Esse host central pode existir so para observabilidade.

## 1. Baixar e instalar

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh --skip-dry-run
```

## 2. Criar o arquivo de nodes

Crie `~/.config/openclawnurse/fleet-nodes.json`:

```json
{
  "fleetName": "Minha Fleet OpenClaw",
  "overallKumaPushUrl": "",
  "nodes": [
    {
      "id": "vps-sp-1",
      "name": "Sao Paulo VPS",
      "feedUrl": "https://vps-sp-1.example.com/openclawnurse/node-feed.json",
      "dashboardUrl": "https://vps-sp-1.example.com",
      "kumaPushUrl": "",
      "tags": ["prod", "telegram"]
    },
    {
      "id": "vps-us-1",
      "name": "US VPS",
      "feedUrl": "https://vps-us-1.example.com/openclawnurse/node-feed.json",
      "dashboardUrl": "https://vps-us-1.example.com",
      "kumaPushUrl": "",
      "tags": ["prod", "whatsapp"]
    }
  ]
}
```

## 3. Configurar o host central

Edite `~/.config/openclawnurse/openclawnurse.env` e deixe algo assim:

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
FLEET_DASHBOARD_PUSH_KUMA="false"
FLEET_DASHBOARD_ON_CALENDAR="*-*-* *:02/5:00"
```

Se esse host nao tem gateway OpenClaw local, tudo bem. O valor aqui e o agregador.

## 4. Reaplicar a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh --skip-dry-run
```

## 5. Testar

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard-run.sh \
  --config ~/.config/openclawnurse/openclawnurse.env

jq . ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json
```

## 6. Conferir timer

```bash
systemctl --user status openclaw-fleet-dashboard.timer --no-pager
```

## 7. Publicar

Se `FLEET_DASHBOARD_PUBLISH_DIR` estiver configurado, os arquivos finais ficam aqui:

```bash
/srv/www/openclaw-fleet/index.html
/srv/www/openclaw-fleet/fleet-status.json
```

Sirva esse diretorio por Nginx, Caddy ou outro web server simples.
