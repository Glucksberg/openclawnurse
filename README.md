# OpenClawNurse

OpenClawNurse e um utilitario portavel para manter instancias do OpenClaw saudaveis com:

- verificacao automatica de update
- diagnostico e reparo nao interativo
- reinicio controlado do gateway
- health check apos manutencao
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

Se o seu gateway OpenClaw for supervisionado por `pm2`, ajuste o arquivo `~/.config/openclawnurse/openclawnurse.env` para usar:

- `RESTART_MODE="custom"`
- `RESTART_COMMAND="pm2 restart openclaw-gateway"`

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
