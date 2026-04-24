# OpenClawNurse

OpenClawNurse e um utilitario portavel para manter instancias do OpenClaw saudaveis com:

- verificacao automatica de update
- diagnostico e reparo nao interativo
- reinicio controlado do gateway
- health check apos manutencao
- relatorio local e via Telegram
- instalacao repetivel em multiplas maquinas
- feed por no para monitoramento centralizado
- agregacao de fleet em JSON + HTML
- publish estatico do dashboard
- plano de remediacao assistida com guardrails

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

Se o seu gateway OpenClaw for supervisionado por `pm2`, ajuste o arquivo `~/.config/openclawnurse/openclawnurse.env` para usar:

- `RESTART_MODE="custom"`
- `RESTART_COMMAND="pm2 restart openclaw-gateway"`

Se o host usar bins fora do PATH padrao do usuario, como Linuxbrew, adicione por config:

- `EXTRA_PATH="/home/linuxbrew/.linuxbrew/bin"`

## Arquivos principais

- `scripts/openclaw-doctor.sh` runtime principal
- `scripts/openclaw-fleet-export.sh` feed JSON por no
- `scripts/openclaw-fleet-dashboard.sh` agregador central + pagina HTML
- `scripts/openclaw-fleet-export-run.sh` wrapper para timer/cron do feed
- `scripts/openclaw-fleet-dashboard-run.sh` wrapper para timer/cron do dashboard
- `scripts/openclaw-fleet-remediation-plan.sh` plano de acao seguro para operacao central
- `scripts/install-doctor.sh` instalador idempotente
- `systemd/` templates de `systemd --user`
- `config/openclaw-doctor.env.example` exemplo de configuracao
- `config/fleet-nodes.example.json` exemplo de fleet centralizado
- `config/fleet-remediation-policy.example.json` politica de guardrails para remediacao
- `docs/PLAN.md` plano v2
- `docs/CARTILHA.md` guia de instalacao e uso
- `docs/REVIEW.md` revisao tecnica da ferramenta
- `docs/FLEET.md` operacao do dashboard central

## Comandos uteis

- `./install.sh`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --self-test`
- `~/.local/share/openclawnurse/bin/openclaw-doctor.sh --dry-run`
- `~/.local/share/openclawnurse/bin/openclaw-fleet-export-run.sh --config ~/.config/openclawnurse/openclawnurse.env`
- `~/.local/share/openclawnurse/bin/openclaw-fleet-dashboard-run.sh --config ~/.config/openclawnurse/openclawnurse.env`
- `~/.local/share/openclawnurse/bin/openclaw-fleet-remediation-plan.sh --fleet-status ~/.local/state/openclawnurse/fleet-dashboard/fleet-status.json --policy ~/.local/share/openclawnurse/config-examples/fleet-remediation-policy.example.json`
- `systemctl --user status openclawnurse.timer`
- `systemctl --user status openclaw-fleet-export.timer`
- `systemctl --user status openclaw-fleet-dashboard.timer`
- `journalctl --user -u openclawnurse.service -n 200 --no-pager`
