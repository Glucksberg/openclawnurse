# Cartilha do OpenClawNurse

## Objetivo

Esta cartilha e para o fluxo que voce vai usar agora:

- uma VPS por instancia
- um OpenClaw por VPS
- um `openclawnurse` por VPS
- um grupo de Telegram separado por VPS
- sem dashboard central
- sem fleet entre hosts

Se voce quiser retomar a parte multi-host no futuro, veja:

- [future-planning/FLEET.md](/home/dev/projects/openclawnurse/docs/future-planning/FLEET.md)

## Arquivos que importam agora

- [AGENT-REMOTE-SETUP.md](/home/dev/projects/openclawnurse/docs/AGENT-REMOTE-SETUP.md): mensagem pronta para enviar ao agente OpenClaw da VPS remota
- [SETUP-SINGLE-VPS.md](/home/dev/projects/openclawnurse/docs/SETUP-SINGLE-VPS.md): guia manual para instalar e validar uma VPS isolada

## O que o OpenClawNurse faz

O `openclawnurse` e um job agendado de manutencao do OpenClaw. Ele:

- verifica update do `openclaw`
- roda `openclaw doctor`
- tenta corrigir problemas operacionais simples
- reinicia o gateway quando necessario
- confirma o health depois da manutencao
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

## Fluxo recomendado por VPS

Para cada VPS separada:

1. clonar o repo
2. rodar `./install.sh`
3. ajustar `~/.config/openclawnurse/openclawnurse.env`
4. validar com `--self-test`
5. validar com `--dry-run --no-notify`
6. conferir `openclawnurse.timer`
7. confirmar que o report vai para o grupo de Telegram correto daquela VPS

## Configuracao minima por VPS

Arquivo:

- `~/.config/openclawnurse/openclawnurse.env`

Exemplo minimo:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
REPORT_CHANNEL="telegram"
AUTO_DETECT_TELEGRAM_TARGET="true"
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
RESTART_MODE="custom"
RESTART_COMMAND="pm2 restart openclaw-gateway"
NODE_COMPILE_CACHE="/var/tmp/openclaw-compile-cache"
OPENCLAW_NO_RESPAWN="1"
EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"
REPORT_MAX_CHARS="3500"
LOG_RETENTION_DAYS="30"
LOG_RETENTION_MB="200"
```

Notas:

- troque `TELEGRAM_TARGET` pelo grupo daquela VPS
- se o gateway nao estiver no `pm2`, ajuste `RESTART_MODE`
- se nao usa Linuxbrew, remova `EXTRA_PATH`

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

## Comandos uteis

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
