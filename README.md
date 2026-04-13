# OpenClawNurse

OpenClawNurse e um utilitario portavel para manter instancias do OpenClaw saudaveis com:

- verificacao automatica de update
- diagnostico e reparo nao interativo
- reinicio controlado do gateway
- health check apos manutencao
- relatorio local e via Telegram
- instalacao repetivel em multiplas maquinas

## Objetivo do repositorio

Este repositorio sera a base distribuivel do projeto. Ele deve poder ser clonado em outra maquina e instalado sem depender de paths hardcoded fora do prefixo do usuario.

## Estrutura inicial

- `docs/` documentacao de produto e implementacao
- `scripts/` scripts executaveis e instalador
- `systemd/` units para `systemd --user`
- `config/` exemplos de configuracao local

## Proximo passo

Implementar os artefatos da v2 descritos em `docs/PLAN.md`.
