# Cartilha do OpenClawNurse

## Objetivo

Esta cartilha resume a operacao padrao do OpenClawNurse em qualquer host com OpenClaw instalado. O objetivo e manter a instalacao local saudavel, com manutencao agendada, reparos seguros e relatorios auditaveis.

A implementacao antiga de fleet/multihost foi compactada em `legacy/openclawnurse-fleet-multihost-legacy-2026-05-05.tar.gz` e nao faz parte do fluxo principal.

## Arquivos que importam agora

- [AGENT-REMOTE-SETUP.md](/home/dev/projects/openclawnurse/docs/AGENT-REMOTE-SETUP.md): mensagem pronta para enviar ao agente OpenClaw da VPS remota
- [SETUP-SINGLE-VPS.md](/home/dev/projects/openclawnurse/docs/SETUP-SINGLE-VPS.md): guia manual para instalar e validar um host

## O que o OpenClawNurse faz

O `openclawnurse` e um job agendado de manutencao do OpenClaw. Ele:

- verifica update do `openclaw`
- roda `openclaw doctor`
- tenta corrigir problemas operacionais simples
- reinicia o gateway quando necessario
- confirma o health depois da manutencao
- verifica drift entre CLI, servico systemd e instalacoes antigas
- confere comandos nativos essenciais do bot Telegram
- procura sintomas recentes no journal do gateway
- grava estado em JSON e logs locais
- envia relatorio para o Telegram do proprio host, se configurado

## Estrutura final no servidor

Depois da instalacao, o layout padrao fica assim:

- runtime: `~/.local/share/openclawnurse`
- config: `~/.config/openclawnurse/openclawnurse.env`
- estado: `~/.local/state/openclawnurse`
- logs: `~/.local/state/openclawnurse/logs`
- units `systemd --user`: `~/.config/systemd/user/`

## Requisitos minimos

Antes de instalar em outra VPS:

- `openclaw` precisa estar instalado e funcional
- `jq`, `timeout`, `sed`, `install` e `flock` precisam existir
- `systemd --user` e recomendado
- se `systemd --user` nao funcionar, o instalador cai para `cron`
- se o gateway OpenClaw for gerenciado por `pm2`, o restart deve ser configurado como `custom`

## Fluxo recomendado

Para cada host:

1. clonar o repo
2. rodar `./install.sh`
3. ajustar `~/.config/openclawnurse/openclawnurse.env`
4. validar com `--self-test`
5. validar com `--dry-run --no-notify`
6. conferir `openclawnurse.timer`
7. confirmar que o report vai para o destino correto, quando notificacoes estiverem habilitadas

## Configuracao minima

Arquivo:

- `~/.config/openclawnurse/openclawnurse.env`

Exemplo minimo:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
TELEGRAM_BOT_TOKEN="123456:ABCDEF..."
REPORT_CHANNEL="telegram"
AUTO_DETECT_TELEGRAM_TARGET="true"
REPORT_INSTANCE_LABEL="host-sp-openclaw-01"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
UPDATE_TIMEOUT="900"
STATUS_TIMEOUT="10"
DOCTOR_TIMEOUT="300"
HEALTH_TIMEOUT_MS="10000"
GATEWAY_WAIT_TIMEOUT="180"
GATEWAY_WAIT_INTERVAL="5"
MAX_CONSECUTIVE_UPDATE_FAILURES="3"
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
PM2_GATEWAY_APP_NAMES="openclaw-gateway openclaw"
ENABLE_RUNTIME_SANITY="true"
ENABLE_TELEGRAM_SANITY="true"
ENABLE_GATEWAY_LOG_SCAN="true"
EXPECTED_OPENCLAW_MODEL=""
EXPECTED_TELEGRAM_COMMANDS="new reset"
GATEWAY_LOG_SINCE="last-run"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
RESTART_COMMAND=""
NODE_COMPILE_CACHE="/var/tmp/openclaw-compile-cache"
OPENCLAW_NO_RESPAWN="1"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"
REPORT_MAX_CHARS="3500"
LOG_RETENTION_DAYS="30"
LOG_RETENTION_MB="200"
```

Notas:

- troque `TELEGRAM_TARGET` pelo grupo daquela VPS
- use `REPORT_INSTANCE_LABEL` para identificar o host no relatorio
- mantenha o Gateway OpenClaw em `systemd --user`; se existir um app legado `openclaw-gateway` no PM2, o Nurse remove apenas esse app e garante o systemd ativo
- se nao usa Linuxbrew, remova `EXTRA_PATH`

Remediacao automatica atual:

- limpeza de sessoes com transcripts ausentes
- arquivamento conservador de transcripts orfaos
- backup/restauracao de config JSON invalida quando ha backup valido
- restart limitado do gateway quando o health fica ruim

Sanidade operacional:

- `ENABLE_RUNTIME_SANITY` detecta binarios `openclaw` divergentes, aliases de shell, schema conhecido de config e mismatch entre CLI e `openclaw-gateway.service`
- `ENABLE_TELEGRAM_SANITY` chama `getMyCommands` no bot configurado do OpenClaw e confirma comandos como `new` e `reset`
- `ENABLE_GATEWAY_LOG_SCAN` varre o journal desde a ultima execucao e marca sintomas como sessao travada, config invalida, warning de provenance de update e erro de provider com input vazio
- `EXPECTED_OPENCLAW_MODEL` pode ser preenchido para exigir um modelo especifico; valores legados `openai-codex/*` sao normalizados para a rota canonica `openai/*`

## Validacao minima por VPS

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

## Leitura rapida de status

- `OK`: rodou bem sem update necessario
- `UPDATED`: update aplicado com sucesso
- `UPDATED_WITH_REPAIRS`: update aplicado e doctor fez correcoes
- `DEGRADED`: o OpenClaw segue de pe, mas o doctor encontrou algo relevante
- `FAILED`: houve falha operacional local
- `FAILED_NOTIFICATION_PENDING`: a rodada terminou, mas a entrega remota ficou pendente

## Problemas comuns

### `TELEGRAM_TARGET` vazio

Sintoma:

- a notificacao nao sai

Correcao:

- preencher `TELEGRAM_TARGET` manualmente no arquivo `.env`

### `TELEGRAM_BOT_TOKEN` vazio

Sintoma:

- a notificacao nao sai

Correcao:

- preencher `TELEGRAM_BOT_TOKEN` manualmente no arquivo `.env`

### `systemd --user` nao funciona

Sintoma:

- `./install.sh` cai para `cron` ou falha ao habilitar o timer

Correcao:

- usar `./install.sh --scheduler cron`

### `DEGRADED` no dry-run

Sintoma:

- o script roda, mas o `doctor` encontra pendencias reais do host

Correcao:

- ler `doctor-state.json`
- revisar `outputs.doctor`
- decidir se essas pendencias devem ser corrigidas automaticamente ou nao

### Sessoes com transcripts ausentes

Sintoma:

- `doctor` reporta `missing transcripts`

Comportamento atual:

- se `AUTO_REMEDIATE_MISSING_TRANSCRIPTS=true`, o OpenClawNurse tenta limpar automaticamente essas entradas em execucao real
- em `--dry-run`, ele apenas reporta quantas entradas seriam removidas

### CLI e gateway em versoes diferentes

Sintoma:

- report com `OpenClaw binary version drift` ou `Gateway ExecStart uses OpenClaw package`

Correcao:

- remover aliases antigos de shell
- reinstalar/recarregar o gateway a partir da instalacao atual do OpenClaw
- conferir `command -v -a openclaw` e `systemctl --user cat openclaw-gateway.service`

### `/new` ou `/reset` quebrando no Telegram

Sintoma:

- report com `provider empty-input error`
- ou `Telegram native command menu is missing required commands`

Correcao:

- reiniciar o gateway
- confirmar que `channels.telegram.commands.native` esta ativo
- se o erro for do runtime gerando input vazio, corrigir no OpenClaw upstream; o OpenClawNurse reporta o sintoma, mas nao aplica patch em `node_modules`

## Atualizacao do proprio OpenClawNurse

Quando o repositório for atualizado:

```bash
./install.sh
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --self-test
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --dry-run
systemctl --user status openclawnurse.timer
journalctl --user -u openclawnurse.service -n 200 --no-pager
jq . ~/.local/state/openclawnurse/doctor-state.json
```

## Resultado esperado

Ao final do setup de uma VPS isolada, voce quer ver:

- `openclawnurse.timer` ativo
- `doctor-state.json` sendo atualizado
- `self-test` passando
- `dry-run` passando ou, se houver findings reais, com explicacao clara
- grupo do Telegram daquela VPS recebendo o report correto

## Se voce for delegar para um agente OpenClaw remoto

Nao improvisa no prompt.

Use este arquivo:

- [AGENT-REMOTE-SETUP.md](/home/dev/projects/openclawnurse/docs/AGENT-REMOTE-SETUP.md)

Ele ja pede para o agente:

- instalar o nurse
- configurar tudo
- validar o setup
- te devolver um relatorio final
- dizer exatamente quais comandos ainda dependem de voce
