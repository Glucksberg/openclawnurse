# Fleet Dashboard

## Objetivo

Monitorar varias instancias OpenClaw a partir de um ponto central, com:

- status consolidado em uma pagina unica
- feed JSON por no
- agregacao central por API HTTP ou arquivo local
- opcao de push para Uptime Kuma

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
2. Gerar o feed periodicamente.
3. Servir esse JSON via HTTP ou sincronizar para o host central.

Exemplo de cron simples do feed:

```bash
*/5 * * * * ~/.local/share/openclawnurse/bin/openclaw-fleet-export.sh --output ~/.local/state/openclawnurse/fleet/node-feed.json >/dev/null 2>&1
```

### No host central

1. Criar `fleet-nodes.json`.
2. Rodar o agregador em intervalo curto.
3. Publicar o `index.html` gerado em qualquer web server simples.

Exemplo:

```bash
mkdir -p ~/.local/state/openclawnurse/fleet-dashboard
~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard.sh \
  --config ~/openclawnurse/config/fleet-nodes.json \
  --output-dir ~/.local/state/openclawnurse/fleet-dashboard
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

## Proximo passo sugerido

Depois do MVP:

- scheduler dedicado para export/agregacao
- assinatura/token para proteger feeds HTTP
- historico de execucoes por no
- remediacao remota por politica
- heuristicas com LLM so para classificar e sugerir acao, nunca como unica fonte de verdade
