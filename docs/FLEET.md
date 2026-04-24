# Fleet Dashboard

## Objetivo

Monitorar varias instancias OpenClaw a partir de um ponto central, com:

- status consolidado em uma pagina unica
- feed JSON por no
- agregacao central por API HTTP ou arquivo local
- publish estatico do dashboard e da API JSON
- opcao de push para Uptime Kuma
- plano de remediacao assistida com guardrails

## Componentes

### 1. Feed por no

Script:

- `~/.local/share/openclawnurse/bin/openclaw-fleet-export.sh`

Ele le o `doctor-state.json` do nurse e tenta anexar um snapshot curto de `openclaw status --json`.

Exemplo:

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-export.sh \
  --config ~/.config/openclawnurse/openclawnurse.env \
  --node-id vps-sp-1 \
  --node-name "Sao Paulo VPS" \
  --public-url "https://vps-sp-1.example.com" \
  --output ~/.local/state/openclawnurse/fleet/node-feed.json
```

Campos principais do feed:

- `node`
- `checks.auth`
- `checks.gateway`
- `checks.update`
- `nurse.status`
- `nurse.doctorSummary`
- `openclaw.snapshot`

## 2. Agregador central

Script:

- `~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh`

Ele busca varios feeds, calcula um status de fleet e gera:

- `fleet-status.json`
- `index.html`

Exemplo:

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh \
  --config ~/openclawnurse/config/fleet-nodes.json \
  --output-dir ~/.local/state/openclawnurse/fleet-dashboard
```

Com publicacao e historico:

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh \
  --config ~/.config/openclawnurse/fleet-nodes.json \
  --output-dir ~/.local/state/openclawnurse/fleet-dashboard \
  --publish-dir /srv/www/openclaw-fleet \
  --history-dir ~/.local/state/openclawnurse/fleet-dashboard-history
```

## 3. Config do fleet

Use como base:

- `config/fleet-nodes.example.json`

Cada no aceita:

- `id`
- `name`
- `feedUrl`
- `dashboardUrl`
- `kumaPushUrl`
- `tags`

`feedUrl` pode ser:

- `https://...`
- `http://...`
- caminho local
- `file:///...`

## Como operar

### Em cada VPS

1. Rodar o nurse normalmente.
2. Habilitar `FLEET_EXPORT_ENABLED="true"` no `openclawnurse.env`.
3. Ajustar `FLEET_EXPORT_NODE_ID`, `FLEET_EXPORT_NODE_NAME` e `FLEET_EXPORT_PUBLIC_URL`.
4. Reinstalar com `./install.sh` para materializar `openclaw-fleet-export.timer`.
5. Servir esse JSON via HTTP ou sincronizar para o host central.

### No host central

1. Criar `fleet-nodes.json`.
2. Habilitar `FLEET_DASHBOARD_ENABLED="true"` no `openclawnurse.env`.
3. Ajustar `FLEET_DASHBOARD_CONFIG_FILE`, `FLEET_DASHBOARD_OUTPUT_DIR` e `FLEET_DASHBOARD_PUBLISH_DIR`.
4. Reinstalar com `./install.sh` para materializar `openclaw-fleet-dashboard.timer`.
5. Publicar o `index.html` e o `fleet-status.json` em qualquer web server simples.

Exemplo:

```bash
mkdir -p ~/.local/state/openclawnurse/fleet-dashboard
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh \
  --config ~/openclawnurse/config/fleet-nodes.json \
  --output-dir ~/.local/state/openclawnurse/fleet-dashboard \
  --publish-dir /srv/www/openclaw-fleet
```

## Uptime Kuma

O agregador suporta push opcional para Kuma:

- `overallKumaPushUrl` no topo da config para o estado global
- `kumaPushUrl` por no para monitores individuais

Para ativar:

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh \
  --config ~/openclawnurse/config/fleet-nodes.json \
  --output-dir ~/.local/state/openclawnurse/fleet-dashboard \
  --push-kuma
```

## Modelo operacional recomendado

- cada OpenClaw continua autonomo com o nurse local
- cada no exporta um feed leve
- um host central agrega tudo
- o dashboard e apenas leitura
- a automacao de reparo continua no no, nao no agregador
- o estado `repaired` conta como saudavel no agregado, mas continua visivel no detalhe do feed

## Timers instalados

Quando habilitados no `openclawnurse.env`, o instalador passa a renderizar:

- `openclaw-fleet-export.service` e `openclaw-fleet-export.timer`
- `openclaw-fleet-dashboard.service` e `openclaw-fleet-dashboard.timer`

No fallback de `cron`, ele instala entradas equivalentes.

## Publicacao

O agregado ja e uma mini API:

- `fleet-status.json` para automacoes, alertas e integracoes
- `index.html` para operadores humanos

Com `--publish-dir`, os dois arquivos sao copiados de forma atomica para um diretorio estatico. Isso permite expor tudo por Nginx, Caddy, S3-compatible sync ou outro host simples.

## Remediacao assistida

Script:

- `~/.local/share/openclawnurse/bin/openclaw-fleet-remediation-plan.sh`

Ele nao executa nada. Ele le o `fleet-status.json`, aplica uma politica de guardrails e gera um plano com:

- categoria do incidente
- acao sugerida
- se a acao e elegivel para automacao
- se a acao exige aprovacao humana
- `commandHint` para o operador
- `llmBrief` curto para ser entregue a um modelo

Exemplo:

```bash
~/.local/share/openclawnurse/bin/openclaw-fleet-remediation-plan.sh \
  --fleet-status ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json \
  --policy ~/.local/share/openclawnurse/config-examples/fleet-remediation-policy.example.json \
  --output ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.json \
  --markdown ~/.local/state/openclawnurse/fleet-dashboard/remediation-plan.md
```

Guardrails do desenho atual:

- LLM apenas classifica, resume e prioriza
- nenhuma execucao remota acontece por padrao
- acoes ficam limitadas ao allowlist da politica
- acoes sensiveis, como restart de gateway, podem exigir aprovacao humana
- comandos destrutivos ficam fora da politica por contrato
