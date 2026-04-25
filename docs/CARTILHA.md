# Cartilha do OpenClawNurse

## Objetivo

Esta cartilha e para voce copiar e usar em outros servidores.

Ela cobre 3 cenarios:

- servidor novo onde ainda nao existe `openclawnurse`
- servidor que vai participar da fleet como `node`
- servidor central que vai agregar tudo e publicar o dashboard

Importante:

- o host central pode ser outro servidor, separado deste
- ele nao precisa hospedar um OpenClaw produtivo
- ele so precisa conseguir ler os feeds dos nodes e publicar os artefatos do dashboard

## Guias rapidos para copiar e colar

Se voce quer ir direto ao ponto, use estes 3 arquivos:

- [SETUP-NODE.md](/home/dev/projects/openclawnurse/docs/SETUP-NODE.md)
- [SETUP-HOST-CENTRAL.md](/home/dev/projects/openclawnurse/docs/SETUP-HOST-CENTRAL.md)
- [SETUP-HOST-CENTRAL-KUMA.md](/home/dev/projects/openclawnurse/docs/SETUP-HOST-CENTRAL-KUMA.md)

## O que o OpenClawNurse faz

O `openclawnurse` e um job agendado de manutencao do OpenClaw. Ele:

- verifica update do `openclaw`
- roda `openclaw doctor`
- tenta corrigir problemas operacionais simples
- reinicia o gateway quando necessario
- confirma o health depois da manutencao
- grava estado em JSON e logs locais
- pode mandar relatorio para Telegram

Na stack de fleet, ele tambem pode:

- exportar um feed JSON por servidor
- agregar varios feeds em um host central
- gerar `fleet-status.json` e `index.html`
- produzir um plano de remediacao com guardrails

## Requisitos minimos

Antes de instalar em outro servidor:

- `openclaw` precisa estar instalado e funcional
- `jq`, `timeout`, `sed`, `install` e `flock` precisam existir
- `systemd --user` e recomendado
- se `systemd --user` nao funcionar, o instalador cai para `cron`
- se o gateway OpenClaw for gerenciado por `pm2`, o restart deve ser configurado como `custom`

## Estrutura final no servidor

Depois da instalacao, o layout padrao fica assim:

- runtime: `~/.local/share/openclawnurse`
- config: `~/.config/openclawnurse/openclawnurse.env`
- estado: `~/.local/state/openclawnurse`
- logs: `~/.local/state/openclawnurse/logs`
- units `systemd --user`: `~/.config/systemd/user/`

## Receita 1: instalar do zero em um servidor novo

Use isso quando ainda nao existe `openclawnurse` no host.

### Passo 1. Baixar o repo

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
```

### Passo 2. Rodar a instalacao

Modo padrao:

```bash
./install.sh
```

Se quiser forcar `cron`:

```bash
./install.sh --scheduler cron
```

Se quiser instalar sem habilitar timer ainda:

```bash
./install.sh --skip-enable --skip-dry-run
```

### Passo 3. Ajustar a configuracao base

Edite:

- `~/.config/openclawnurse/openclawnurse.env`

Exemplo minimo:

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
```

Notas:

- se o gateway nao estiver no `pm2`, ajuste `RESTART_MODE` para o modo real do host
- se nao usa Linuxbrew, remova `EXTRA_PATH`

### Passo 4. Validar

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --self-test \
  --no-notify

~/.local/share/openclawnurse/bin/openclaw-doctor.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --dry-run \
  --no-notify
```

### Passo 5. Conferir o agendamento

Se usa `systemd --user`:

```bash
systemctl --user status openclawnurse.timer --no-pager
systemctl --user status openclawnurse.service --no-pager
journalctl --user -u openclawnurse.service -n 200 --no-pager
```

Se usa `cron`:

```bash
crontab -l
tail -n 200 ~/.local/state/openclawnurse/logs/cron.log
```

## Receita 2: transformar um servidor em node da fleet

Use isso em cada VPS que deve aparecer no dashboard central.

### Passo 1. Garanta que o nurse basico ja esta instalado

Se nao estiver, siga a `Receita 1` antes.

### Passo 2. Habilite a exportacao do feed

Edite `~/.config/openclawnurse/openclawnurse.env` e adicione:

```bash
FLEET_EXPORT_ENABLED="true"
FLEET_EXPORT_NODE_ID="vps-sp-1"
FLEET_EXPORT_NODE_NAME="Sao Paulo VPS"
FLEET_EXPORT_PUBLIC_URL="https://vps-sp-1.example.com"
FLEET_EXPORT_OUTPUT="$HOME/.local/state/openclawnurse/fleet/node-feed.json"
FLEET_EXPORT_INCLUDE_STATUS="true"
FLEET_EXPORT_STATUS_TIMEOUT="10"
FLEET_EXPORT_ON_CALENDAR="*-*-* *:00/5:00"
```

Ajuste os 3 campos principais:

- `FLEET_EXPORT_NODE_ID`: identificador estavel do servidor
- `FLEET_EXPORT_NODE_NAME`: nome humano
- `FLEET_EXPORT_PUBLIC_URL`: URL do host, se existir

### Passo 3. Reaplique a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh
```

Isso materializa:

- `openclaw-fleet-export.service`
- `openclaw-fleet-export.timer`

### Passo 4. Teste o feed

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-export-run.sh \
  --config ~/.config/openclawnurse/openclawnurse.env

jq . ~/.local/state/openclawnurse/fleet/node-feed.json
```

### Passo 5. Confira o timer

```bash
systemctl --user status openclaw-fleet-export.timer --no-pager
systemctl --user status openclaw-fleet-export.service --no-pager
```

### Passo 6. Exponha esse JSON para o host central

Voce pode fazer de 3 formas:

- servir por HTTP, por exemplo `https://host/openclawnurse/node-feed.json`
- sincronizar para um diretório comum no host central
- ler via `file://` ou caminho local compartilhado

O arquivo que interessa e:

- `~/.local/state/openclawnurse/fleet/node-feed.json`

## Receita 3: transformar um servidor em host central da fleet

Use isso em um unico host, o agregador central.

Esse host central pode ser um servidor totalmente separado, dedicado so para observabilidade.

### Passo 1. Garanta que o nurse basico ja esta instalado

Se nao estiver, siga a `Receita 1` antes.

Se esse host central ainda nao tem nada instalado, use esta sequencia completa:

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh --skip-dry-run
```

Depois ajuste o arquivo:

- `~/.config/openclawnurse/openclawnurse.env`

Com base minima:

```bash
REPORT_CHANNEL="telegram"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
RESTART_MODE="custom"
RESTART_COMMAND="pm2 restart openclaw-gateway"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"
FLEET_DASHBOARD_ENABLED="true"
```

Se esse host central nao tiver gateway OpenClaw rodando, voce pode manter o nurse instalado apenas para reutilizar scheduler, logs e os scripts da fleet. Nesse caso, foque na parte `FLEET_DASHBOARD_*` e use `--skip-dry-run` na instalacao inicial.

### Passo 2. Crie o arquivo de nos

Crie:

- `~/.config/openclawnurse/fleet-nodes.json`

Exemplo:

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

### Passo 3. Habilite a agregacao central

Edite `~/.config/openclawnurse/openclawnurse.env` e adicione:

```bash
FLEET_DASHBOARD_ENABLED="true"
FLEET_DASHBOARD_CONFIG_FILE="$HOME/.config/openclawnurse/fleet-nodes.json"
FLEET_DASHBOARD_OUTPUT_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard"
FLEET_DASHBOARD_PUBLISH_DIR="/srv/www/openclaw-fleet"
FLEET_DASHBOARD_HISTORY_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard-history"
FLEET_DASHBOARD_PUSH_KUMA="false"
FLEET_DASHBOARD_ON_CALENDAR="*-*-* *:02/5:00"
```

Se nao quiser publicar em `/srv/www/openclaw-fleet`, troque por outro diretorio.

Exemplo pronto para colar no host central:

```bash
cat >> ~/.config/openclawnurse/openclawnurse.env <<'EOF'
FLEET_DASHBOARD_ENABLED="true"
FLEET_DASHBOARD_CONFIG_FILE="$HOME/.config/openclawnurse/fleet-nodes.json"
FLEET_DASHBOARD_OUTPUT_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard"
FLEET_DASHBOARD_PUBLISH_DIR="/srv/www/openclaw-fleet"
FLEET_DASHBOARD_HISTORY_DIR="$HOME/.local/state/openclawnurse/fleet-dashboard-history"
FLEET_DASHBOARD_PUSH_KUMA="false"
FLEET_DASHBOARD_ON_CALENDAR="*-*-* *:02/5:00"
EOF
```

### Passo 4. Reaplique a instalacao

```bash
cd "$HOME/openclawnurse"
./install.sh
```

Isso materializa:

- `openclaw-fleet-dashboard.service`
- `openclaw-fleet-dashboard.timer`

### Passo 5. Teste manualmente

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard-run.sh \
  --config ~/.config/openclawnurse/openclawnurse.env
```

Saidas principais:

- `~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json`
- `~/.local/state/openclawnurse/fleet-dashboard/index.html`

Se `FLEET_DASHBOARD_PUBLISH_DIR` estiver configurado, os mesmos arquivos sao copiados para esse diretorio:

- `fleet-status.json`
- `index.html`

Se esse diretorio for servido por Nginx ou Caddy, a pagina central ja fica acessivel por browser.

### Passo 6. Confira o timer

```bash
systemctl --user status openclaw-fleet-dashboard.timer --no-pager
systemctl --user status openclaw-fleet-dashboard.service --no-pager
```

## Receita 4: gerar plano de remediacao assistida

Esse passo e opcional.

Ele nao executa nada. Ele apenas gera um plano seguro com sugestoes.

### Passo 1. Rode o planner

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-remediation-plan.sh \
  --fleet-status ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json \
  --policy ~/.local/share/openclawnurse/config-examples/fleet-remediation-policy.example.json \
  --output ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.json \
  --markdown ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.md
```

### Passo 2. Leia os resultados

Arquivos gerados:

- `remediation-plan.json`
- `remediation-plan.md`

Esse plano informa:

- categoria do incidente
- acao sugerida
- se a acao e elegivel para automacao
- se a acao exige aprovacao humana

## Comandos uteis do dia a dia

### Ver estado atual do nurse

```bash
jq . ~/.local/state/openclawnurse/doctor-state.json
```

### Ver logs do nurse

```bash
journalctl --user -u openclawnurse.service -n 200 --no-pager
tail -n 200 ~/.local/state/openclawnurse/logs/doctor-*.log
```

### Ver logs do export da fleet

```bash
journalctl --user -u openclaw-fleet-export.service -n 200 --no-pager
tail -n 200 ~/.local/state/openclawnurse/logs/fleet-export-cron.log
```

### Ver logs do agregador central

```bash
journalctl --user -u openclaw-fleet-dashboard.service -n 200 --no-pager
tail -n 200 ~/.local/state/openclawnurse/logs/fleet-dashboard-cron.log
```

## Leitura rapida dos status

### Status do nurse

- `OK`: rodou bem
- `UPDATED`: aplicou update com sucesso
- `UPDATED_WITH_REPAIRS`: aplicou update e corrigiu algo
- `DEGRADED`: achou pendencia relevante
- `FAILED`: falha operacional
- `FAILED_NOTIFICATION_PENDING`: rodada local terminou, mas a notificacao ficou pendente

### Status agregado da fleet

- `ok`: servidor saudavel
- `warn`: servidor em alerta, mas ainda operante
- `down`: sem feed, auth quebrado, gateway ruim ou nurse falhou

Observacao importante:

- `repaired` aparece no detalhe do feed, mas no agregado conta como `ok`

## Problemas comuns

### `TELEGRAM_TARGET` vazio

Sintoma:

- notificacao nao sai

Correcao:

- preencher `TELEGRAM_TARGET` no `openclawnurse.env`

### `systemd --user` nao funciona

Sintoma:

- o timer nao habilita

Correcao:

```bash
./install.sh --scheduler cron
```

### `openclaw-fleet-export.timer` nao aparece

Sintoma:

- o nurse existe, mas nao existe timer da fleet

Correcao:

- conferir `FLEET_EXPORT_ENABLED="true"`
- rodar `./install.sh` novamente

### `openclaw-fleet-dashboard.timer` nao aparece

Sintoma:

- o host central nao agrega nada automaticamente

Correcao:

- conferir `FLEET_DASHBOARD_ENABLED="true"`
- conferir `FLEET_DASHBOARD_CONFIG_FILE`
- rodar `./install.sh` novamente

### Host central sem OpenClaw local

Sintoma:

- voce quer so agregar a fleet em um servidor separado

Comportamento esperado:

- isso e suportado
- o valor principal nesse host e o agregador, nao o `doctor`

Como operar:

- instalar com `./install.sh --skip-dry-run`
- configurar `FLEET_DASHBOARD_*`
- rodar `./install.sh` novamente depois de ajustar o `.env`
- validar apenas o fluxo do dashboard com `openclaw-fleet-dashboard-run.sh`

### Dashboard vazio

Sintoma:

- `index.html` existe, mas todos os nos aparecem como `down`

Correcao:

- testar cada `feedUrl` manualmente com `curl`
- validar `fleet-nodes.json`
- gerar o feed manualmente no node
- confirmar permissao de leitura ou publicacao HTTP

### `DEGRADED` no `dry-run`

Sintoma:

- o script rodou, mas o `doctor` encontrou pendencias reais

Correcao:

- abrir `doctor-state.json`
- revisar `outputs.doctor`
- decidir se a correcao deve ser automatica ou manual

## Atualizacao do proprio OpenClawNurse

Quando o repo for atualizado:

```bash
cd "$HOME/openclawnurse"
git pull
./install.sh
```

Isso reaplica scripts, templates e timers de forma idempotente.

## Fluxo mental simples

- cada VPS cuida do proprio OpenClaw
- cada VPS exporta um feed
- um host central agrega tudo
- voce olha uma pagina so
- se algo quebrar, o planner sugere o proximo passo
