# OpenClawNurse

OpenClawNurse e um utilitario portavel para manter instancias do OpenClaw saudaveis com:

- verificacao automatica de update
- diagnostico e reparo nao interativo
- reinicio controlado do gateway
- health check apos manutencao
- checks de sanidade para instalacao duplicada, config, Telegram e logs do gateway
- relatorio local e via Telegram
- instalacao repetivel em multiplas maquinas

O fluxo principal deste repo, hoje, e:

- uma VPS por instancia
- um OpenClaw por VPS
- um openclawnurse por VPS
- um grupo de Telegram por VPS
- sem dependencia de host central

Multi-host e fleet continuam no repo, mas foram movidos para `docs/future-planning/`.

## Como instalar

1. Clone o repositorio em qualquer diretorio.
2. Rode `./install.sh`.
3. Ajuste `~/.config/openclawnurse/openclawnurse.env` se quiser alterar target, horario ou comportamento.
4. Rode um `--self-test`.
5. Rode um `--dry-run`.

Para usar o mesmo bot/token de Telegram em varias maquinas, com um `openclawnurse` por host, configure no `.env`:

- `TELEGRAM_BOT_TOKEN` com o bot dedicado de alertas
- `TELEGRAM_TARGET` com o chat/grupo central de alertas
- `REPORT_INSTANCE_LABEL` com um nome claro do host

Esse modo legado envia alertas direto pela API do Telegram e nao depende do OpenClaw. Para instancias OpenClaw comuns, prefira o modo "Alertas pelo proprio OpenClaw" abaixo, que reutiliza o bot/canal ja configurado.

Por padrao, o instalador:

- copia o runtime para `~/.local/share/openclawnurse`
- cria configuracao em `~/.config/openclawnurse/openclawnurse.env`
- grava estado e logs em `~/.local/state/openclawnurse`
- instala `systemd --user` com fallback para `crontab`
- executa um `--dry-run` ao final

## Supervisao do gateway

O `openclawnurse` nao e um daemon de longa duracao. Ele foi desenhado para rodar como job agendado (`systemd timer` ou `cron`), nao como processo permanente no `pm2`.

Por padrao, ele tenta remediar automaticamente dois tipos de sujeira operacional comuns:

- entradas de sessao com transcripts ausentes
- arquivos `*.trajectory.jsonl` orfaos apontados pelo `openclaw doctor`
- config `openclaw.json` invalida, restaurando o ultimo backup JSON valido quando existir

Em hosts com politica de uma unica instalacao do OpenClaw, escolha explicitamente o binario canonico e habilite a remediacao de deriva:

- `OPENCLAW_BIN="$HOME/openclaw/node_modules/.bin/openclaw"`
- `AUTO_REMEDIATE_OPENCLAW_INSTALLATIONS="true"`
- `OPENCLAW_REMEDIABLE_INSTALL_PATHS="$HOME/.npm-global/bin/openclaw $HOME/.npm-global/lib/node_modules/openclaw $HOME/.local/share/pnpm/global/5/node_modules/openclaw"`
- `AUTO_REPAIR_OPENCLAW_LAUNCHER="true"`
- `OPENCLAW_LAUNCHER_PATH="$HOME/.local/share/pnpm/openclaw"`
- `AUTO_REMEDIATE_SHELL_OPENCLAW_SHADOWING="true"`

Essa remediacao nao apaga os caminhos divergentes: ela move os artefatos para `~/.local/state/openclawnurse/quarantine/` e deixa o report registrar o que foi feito.

## Alertas pelo proprio OpenClaw

Quando o Gateway esta saudavel, o alerta pode ser enviado pelo proprio bot/canal do OpenClaw, sem um token dedicado do Nurse. O padrao recomendado e:

- o `openclawnurse.timer` continua executando reparos locais e gravando `doctor-state.json`
- um cronjob do OpenClaw chama um agente leve
- o agente executa `openclawnurse-openclaw-alert.sh`
- o script envia mensagem para o grupo/topico configurado quando o estado esta diferente de `OK` ou quando houve atividade relevante: update aplicado, config restaurada, gateway reiniciado ou remediacao aplicada
- quando havia incidente anterior, ele envia uma recuperacao quando volta a `OK`

Config relevante:

- `OPENCLAW_ALERT_CHANNEL="telegram"`
- `OPENCLAW_ALERT_TARGET="-1001234567890"`
- `OPENCLAW_ALERT_THREAD_ID=""`
- `OPENCLAW_ALERT_AGENT_ID="main"`
- `OPENCLAW_ALERT_EVERY=""`
- `OPENCLAW_ALERT_CRON=""`
- `OPENCLAW_ALERT_TZ=""`
- `OPENCLAW_ALERT_JOB_NAME="openclawnurse-alert"`
- `OPENCLAW_ALERT_MIN_INTERVAL_SECONDS="21600"`
- `OPENCLAW_ALERT_RECOVERY="true"`

O instalador deixa essa parte quase plug and play. Em um terminal interativo, `./install.sh` tenta detectar o primeiro grupo Telegram configurado no OpenClaw, sugere um topico de automacoes quando existir e pergunta:

- caminho do binario `openclaw`
- id do grupo/chat Telegram
- id do topico/forum thread, ou vazio para o grupo principal
- agente que executa o cronjob de alerta
- intervalo do cronjob, quando nao usar cron expression

Para instalacoes automatizadas, passe tudo por flags/env:

```bash
./install.sh \
  --configure-openclaw-alert \
  --openclaw-bin "$HOME/openclaw/node_modules/.bin/openclaw" \
  --openclaw-alert-target "-1001234567890" \
  --openclaw-alert-thread-id "251" \
  --openclaw-alert-agent "automacoes" \
  --openclaw-alert-every "12h"
```

Para agenda fixa em UTC, use cron expression no lugar do intervalo:

```bash
./install.sh \
  --configure-openclaw-alert \
  --openclaw-alert-cron "0 11,21 * * *" \
  --openclaw-alert-tz "UTC"
```

Se o CLI local do OpenClaw ainda nao tiver escopo para gerenciar cron, o instalador nao falha: ele configura o `.env` e informa que voce deve aprovar/reparar os escopos e rodar o instalador de novo.

Se `OPENCLAW_ALERT_CRON` e `OPENCLAW_ALERT_EVERY` estiverem vazios, o instalador assume `OPENCLAW_ALERT_EVERY="12h"` como comportamento padrao.

Quando `OPENCLAW_ALERT_THREAD_ID` estiver preenchido, o instalador tambem aponta o failure alert nativo do cron para o topico usando a sintaxe documentada pelo OpenClaw: `<chatId>:topic:<threadId>`. A entrega normal do job continua usando `delivery.threadId`.

Para evitar duplicidade em updates, o Gateway OpenClaw deve ficar sob `systemd --user`:

- `RESTART_MODE="systemd_user"`
- `SYSTEMD_UNIT_NAME="openclaw-gateway.service"`
- `AUTO_MIGRATE_PM2_GATEWAY_TO_SYSTEMD="true"`
- `PM2_GATEWAY_APP_NAMES="openclaw-gateway openclaw"`

Se um app legado chamado exatamente `openclaw-gateway` ou `openclaw` aparecer no PM2, o Nurse pode remover apenas esse app do PM2 e garantir que o `openclaw-gateway.service` esteja habilitado/rodando. Outros apps PM2 nao sao tocados. A lista pode ser ajustada em `PM2_GATEWAY_APP_NAMES`.

Se o host usar bins fora do PATH padrao do usuario, como Linuxbrew, adicione por config:

- `EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"`

## Arquivos principais

- `scripts/openclaw-doctor.sh` runtime principal
- `scripts/install-doctor.sh` instalador idempotente
- `systemd/` templates de `systemd --user`
- `config/openclaw-doctor.env.example` exemplo de configuracao
- `docs/PLAN.md` plano v2
- `docs/CARTILHA.md` cartilha principal para VPS isolada
- `docs/SETUP-SINGLE-VPS.md` guia rapido de setup manual
- `docs/AGENT-REMOTE-SETUP.md` prompt pronto para enviar ao agente remoto
- `docs/future-planning/` documentacao de fleet e host central
- `docs/REVIEW.md` revisao tecnica da ferramenta

## Comandos uteis

- `./install.sh`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --self-test`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --dry-run`
- `systemctl --user status openclawnurse.timer`
- `journalctl --user -u openclawnurse.service -n 200 --no-pager`

## Validacao local

Antes de publicar mudancas, rode:

```bash
bash -n install.sh
for script in scripts/*.sh; do bash -n "$script"; done
jq empty config/*.json
scripts/test-smoke.sh
```

O CI do GitHub Actions executa essas mesmas validacoes. Ele tambem roda `shellcheck` como aviso nao bloqueante.

## Planejamento futuro

Os scripts e configuracoes de multi-host continuam disponiveis no repo:

- `scripts/openclaw-fleet-export.sh`
- `scripts/openclaw-fleet-dashboard.sh`
- `scripts/openclaw-fleet-remediation-plan.sh`
- `scripts/openclaw-fleet-remediation-exec.sh`
- `config/fleet-nodes.example.json`
- `config/fleet-remediation-policy.example.json`

Mas a documentacao correspondente foi movida para:

- `docs/future-planning/`
