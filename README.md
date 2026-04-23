# OpenClawNurse

OpenClawNurse e um utilitario portavel para manter instancias do OpenClaw saudaveis com:

- verificacao automatica de update
- diagnostico e reparo nao interativo
- reinicio controlado do gateway
- health check apos manutencao
- relatorio local e via Telegram
- instalacao repetivel em multiplas maquinas

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

Se o seu gateway OpenClaw for supervisionado por `pm2`, ajuste o arquivo `~/.config/openclawnurse/openclawnurse.env` para usar:

- `RESTART_MODE="custom"`
- `RESTART_COMMAND="pm2 restart openclaw-gateway"`

## Arquivos principais

- `scripts/openclaw-doctor.sh` runtime principal
- `scripts/install-doctor.sh` instalador idempotente
- `systemd/` templates de `systemd --user`
- `config/openclaw-doctor.env.example` exemplo de configuracao
- `docs/PLAN.md` plano v2
- `docs/CARTILHA.md` guia de instalacao e uso
- `docs/REVIEW.md` revisao tecnica da ferramenta

## Comandos uteis

- `./install.sh`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --self-test`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --dry-run`
- `systemctl --user status openclawnurse.timer`
- `journalctl --user -u openclawnurse.service -n 200 --no-pager`
