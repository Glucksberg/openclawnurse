# OpenClaw Doctor v2 — Auto-Update Autonomo com Diagnostico, Estado Persistente e Relatorio via Telegram

## Objetivo

Criar um "doctor proprietario" realmente autonomo para o OpenClaw que:

- rode sozinho em cada instancia
- verifique atualizacoes com seguranca
- aplique update quando permitido pela politica
- execute diagnostico e reparo nao interativo
- reinicie o gateway apenas quando necessario
- confirme que o servico voltou
- gere relatorio local e remoto
- sobreviva a falhas parciais sem ficar "cego"

O foco da v2 e simplicidade operacional com confiabilidade. O sistema precisa funcionar sem supervisao diaria e sem depender de memoria humana.

## Principios da v2

- uma unica automacao responsavel pelo ciclo completo
- idempotencia: rodar duas vezes nao deve duplicar configuracao nem corromper estado
- lock de execucao: nunca haver duas rodadas simultaneas
- estado persistente: a automacao precisa lembrar o que ocorreu na ultima rodada
- logs locais sempre presentes, mesmo se Telegram falhar
- notificacao e entrega secundaria; persistencia local e a fonte primaria de verdade
- politica de update explicita e conservadora
- parsing defensivo de JSON retornado pelo CLI
- degradacao graciosa quando uma etapa falha

## Decisao de Agendamento

### Preferencia: `systemd --user timer`

A v2 prefere `systemd --user timer` em vez de `crontab`.

Motivos:

- melhor observabilidade com `systemctl --user status` e `journalctl --user`
- controle nativo de retry e dependencia de servicos
- instalacao mais previsivel entre instancias
- menos fragilidade do que editar `crontab`
- continua independente do cron interno do OpenClaw

### Fallback: `crontab`

Se a instancia nao suportar `systemd --user`, o instalador pode cair para `crontab` como modo de compatibilidade.

## Arquitetura v2

```text
systemd --user timer / crontab
    |
    v
openclaw-doctor.sh
    |
    +-- 0. acquire_lock
    +-- 1. load_config
    +-- 2. load_previous_state
    +-- 3. preflight_checks
    +-- 4. check_update_status
    +-- 5. maybe_apply_update
    +-- 6. run_doctor_repair
    +-- 7. maybe_restart_gateway
    +-- 8. wait_for_gateway_health
    +-- 9. build_reports (txt + json)
    +-- 10. persist_state_and_logs
    +-- 11. deliver_telegram_or_queue_retry
    +-- 12. release_lock
```

## Estados do Processo

O script deve trabalhar com estados estruturados, nao com mensagens soltas.

Estados finais:

- `OK`
- `UPDATED`
- `UPDATED_WITH_REPAIRS`
- `DEGRADED`
- `FAILED`
- `FAILED_NOTIFICATION_PENDING`

Campos minimos no estado persistido:

```json
{
  "timestamp": "2026-04-14T04:30:00-04:00",
  "hostname": "instance-a",
  "status": "UPDATED_WITH_REPAIRS",
  "currentVersionBefore": "2026.3.28",
  "currentVersionAfter": "2026.4.12",
  "availableVersion": "2026.4.12",
  "updateAttempted": true,
  "updateSucceeded": true,
  "doctorAttempted": true,
  "doctorSummary": "2 problemas corrigidos",
  "restartAttempted": true,
  "gatewayHealthy": true,
  "notificationDelivered": true,
  "notificationPending": false,
  "consecutiveFailures": 0,
  "durationSeconds": 52
}
```

## Estrutura de Diretorios

```text
~/.openclaw/workspace/scripts/
    openclaw-doctor.sh
    install-doctor.sh

~/.openclaw/state/
    doctor-state.json
    doctor.lock
    pending-report.txt
    pending-report.json

~/.openclaw/logs/doctor/
    doctor-2026-04-14.log
    doctor-2026-04-14.json
    install.log
```

## Plano de Implementacao v2

### Passo 1 — Script principal `openclaw-doctor.sh`

**Arquivo:** `/home/dev/.openclaw/workspace/scripts/openclaw-doctor.sh`

O script sera dividido em funcoes pequenas, com retorno claro por fase.

### Fase 0 — Lock de execucao

- usar `flock` em `~/.openclaw/state/doctor.lock`
- se outra execucao estiver em andamento, sair sem erro fatal e registrar `skip`
- evitar overlap em update, restart e envio

### Fase 1 — Load config

Carregar configuracao de ambiente com defaults seguros:

```bash
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
REPORT_CHANNEL="${REPORT_CHANNEL:-telegram}"
TELEGRAM_TARGET="${TELEGRAM_TARGET:-}"
LOG_DIR="${LOG_DIR:-$HOME/.openclaw/logs/doctor}"
STATE_DIR="${STATE_DIR:-$HOME/.openclaw/state}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOG_RETENTION_MB="${LOG_RETENTION_MB:-200}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_CHANNEL="${UPDATE_CHANNEL:-stable}"
UPDATE_TIMEOUT="${UPDATE_TIMEOUT:-900}"
DOCTOR_TIMEOUT="${DOCTOR_TIMEOUT:-300}"
GATEWAY_WAIT_TIMEOUT="${GATEWAY_WAIT_TIMEOUT:-180}"
GATEWAY_WAIT_INTERVAL="${GATEWAY_WAIT_INTERVAL:-5}"
MAX_CONSECUTIVE_UPDATE_FAILURES="${MAX_CONSECUTIVE_UPDATE_FAILURES:-3}"
RETRY_NOTIFICATION_ON_NEXT_RUN="${RETRY_NOTIFICATION_ON_NEXT_RUN:-true}"
SYSTEMD_UNIT_NAME="${SYSTEMD_UNIT_NAME:-openclaw-gateway.service}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
```

Notas:

- `TELEGRAM_TARGET` deve ser explicito; autodeteccao pode existir apenas como tentativa auxiliar
- `AUTO_UPDATE` precisa poder ser desligado sem editar codigo
- timeouts devem ser por fase, nao apenas no update

### Fase 2 — Load previous state

- ler `doctor-state.json` se existir
- recuperar `consecutiveFailures`
- verificar se ha `pending-report.txt` e `pending-report.json`
- usar isso para reentrega futura do relatorio, se necessario

### Fase 3 — Preflight checks

Validacoes minimas antes de qualquer acao:

- binario `openclaw` existe
- `jq`, `flock`, `timeout`, `systemctl` ou `crontab` disponiveis conforme modo instalado
- diretorios de log e state existem
- se `REPORT_CHANNEL=telegram`, `TELEGRAM_TARGET` esta definido

Se faltar requisito critico:

- gerar relatorio local
- marcar status `FAILED`
- persistir motivo exato

### Fase 4 — Check update status

Executar:

```bash
openclaw update status --json
```

Regras:

- validar JSON antes de usar
- exigir ao menos `currentVersion` e `availableVersion`
- se o schema esperado nao vier, falhar com erro de compatibilidade em vez de seguir no escuro

### Fase 5 — Update condicional com politica

So atualizar se:

- `AUTO_UPDATE=true`
- existe `availableVersion`
- `currentVersion != availableVersion`
- numero de falhas consecutivas de update nao ultrapassou o limite configurado

Execucao:

```bash
openclaw update --json --no-restart --timeout "$UPDATE_TIMEOUT"
```

Comportamento:

- capturar saida JSON ou texto e persistir
- se update falhar, executar um unico `openclaw doctor --repair --non-interactive`
- apos reparo, permitir apenas um retry de update
- se falhar de novo, parar tentativas automaticas naquela rodada
- incrementar contador de falhas consecutivas

A v2 nao deve insistir agressivamente. Autonomia boa significa previsibilidade, nao repeticao cega.

### Fase 6 — Doctor sempre executa

Executar sempre:

```bash
openclaw doctor --repair --non-interactive
```

Classificacao:

- sem problemas: `healthy`
- problemas corrigidos: `repaired`
- problemas detectados mas nao corrigidos: `needs_manual_attention`

Persistir:

- contagem de problemas
- itens corrigidos
- itens pendentes

### Fase 7 — Restart condicional

So reiniciar o gateway se houve update bem-sucedido ou se o doctor indicar necessidade de reciclar o servico.

Execucao:

```bash
systemctl --user restart "$SYSTEMD_UNIT_NAME"
```

Se nao houver `systemd --user`, a estrategia de restart deve ser parametrizada no instalador.

### Fase 8 — Health check com backoff simples

Nao usar timeout unico fixo de 60s.

Estrutura:

- esperar ate `GATEWAY_WAIT_TIMEOUT`
- checar a cada `GATEWAY_WAIT_INTERVAL`
- usar endpoint de health se existir; se nao, usar um comando confiavel e leve do OpenClaw

Se nao subir:

- marcar `gatewayHealthy=false`
- classificar status como `DEGRADED` ou `FAILED`, conforme fase anterior
- ainda assim gerar e persistir relatorio

### Fase 9 — Build de relatorios

Gerar dois artefatos:

- `doctor-YYYY-MM-DD.log` com log humano
- `doctor-YYYY-MM-DD.json` com resultado estruturado

Tambem gerar:

- `pending-report.txt`
- `pending-report.json`

Esses arquivos so sao removidos apos entrega confirmada do relatorio.

### Fase 10 — Persistencia local obrigatoria

Mesmo que tudo falhe, persistir:

- status final
- erros por fase
- duracao total
- versoes antes/depois
- data/hora
- hostname

Atualizar `doctor-state.json` ao final de toda rodada.

### Fase 11 — Entrega do relatorio

Fluxo de notificacao:

1. tentar enviar o relatorio atual
2. se existir relatorio pendente de rodada anterior, tentar enviar tambem
3. se envio falhar, manter pendencia local
4. na proxima rodada, tentar reentrega antes ou depois do relatorio novo

Importante:

- o envio nao pode ser a unica forma de saber que houve falha
- preferir texto simples ou Markdown estritamente escapado
- nao confiar que mensagens de erro de CLI sao seguras para Markdown bruto

### Fase 12 — Rotacao de logs

Regras:

- manter ultimos `LOG_RETENTION_DAYS`
- adicionalmente limitar volume total por `LOG_RETENTION_MB`
- nunca remover `doctor-state.json`

## Formato do Relatorio v2

A v2 deve manter leitura humana simples. Exemplo em texto simples:

```text
OpenClaw Doctor - Relatorio Diario
Data: 2026-04-14 04:30 America/Sao_Paulo
Host: instance-a
Status: UPDATED_WITH_REPAIRS

Versao anterior: 2026.3.28
Versao atual: 2026.4.12
Versao disponivel: 2026.4.12

Update: aplicado com sucesso
Doctor: 2 problemas corrigidos
Restart: executado
Health check: gateway saudavel
Duracao: 52s

Acoes corrigidas:
- sessoes orfas arquivadas
- cron legado normalizado
```

Exemplo de falha:

```text
OpenClaw Doctor - Relatorio Diario
Data: 2026-04-14 04:30 America/Sao_Paulo
Host: instance-a
Status: FAILED_NOTIFICATION_PENDING

Versao anterior: 2026.3.28
Versao atual: 2026.3.28
Versao disponivel: 2026.4.12

Update: falhou apos 2 tentativas
Motivo: timeout no npm install apos 900s
Doctor: executado sem sucesso corretivo suficiente
Restart: nao executado
Health check: nao aplicavel
Duracao: 933s

Acao manual:
- verificar conectividade com registry
- executar update manual com timeout maior

Observacao:
- relatorio remoto pendente; copia salva localmente
```

## Instalacao v2

### Passo 2 — Script `install-doctor.sh`

**Arquivo:** `/home/dev/.openclaw/workspace/scripts/install-doctor.sh`

Responsabilidades:

1. copiar ou atualizar `openclaw-doctor.sh`
2. criar `~/.openclaw/state/` e `~/.openclaw/logs/doctor/`
3. instalar arquivo de configuracao local, se ausente
4. validar dependencias do host
5. configurar `systemd --user service` e `timer` por padrao
6. se `systemd --user` nao estiver disponivel, oferecer fallback para `crontab`
7. evitar instalacao duplicada
8. executar `--dry-run`

### Configuracao local

Sugestao: usar arquivo simples de ambiente:

**Arquivo:** `~/.openclaw/workspace/scripts/openclaw-doctor.env`

Exemplo:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
REPORT_CHANNEL="telegram"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
TIMEZONE="America/Sao_Paulo"
```

Vantagem:

- menos acoplamento com `openclaw.json`
- mais portavel entre instancias
- mais simples de auditar

Autodeteccao do Telegram pode existir, mas apenas como preenchimento inicial quando o valor estiver ausente.

## Units do systemd

### `~/.config/systemd/user/openclaw-doctor.service`

Responsavel por executar o script uma vez.

### `~/.config/systemd/user/openclaw-doctor.timer`

Responsavel por agenda diaria.

Exemplo conceitual:

```ini
[Unit]
Description=OpenClaw Doctor

[Service]
Type=oneshot
EnvironmentFile=%h/.openclaw/workspace/scripts/openclaw-doctor.env
ExecStart=%h/.openclaw/workspace/scripts/openclaw-doctor.sh
```

```ini
[Unit]
Description=Run OpenClaw Doctor daily

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
```

`Persistent=true` ajuda a nao perder uma rodada se a maquina estiver desligada no horario.

## Fallback com crontab

Se for inevitavel usar cron:

```cron
30 4 * * * /home/dev/.openclaw/workspace/scripts/openclaw-doctor.sh >> /home/dev/.openclaw/logs/doctor/cron.log 2>&1
```

Observacoes:

- preferir horario local claro e documentado
- evitar comentario assumindo UTC sem verificar configuracao real do host
- a instalacao precisa descobrir explicitamente se o cron usa timezone local ou outro

## Arquivos a Criar/Modificar

| Arquivo | Acao |
|---------|------|
| `~/.openclaw/workspace/scripts/openclaw-doctor.sh` | Criar script principal v2 |
| `~/.openclaw/workspace/scripts/install-doctor.sh` | Criar instalador idempotente |
| `~/.openclaw/workspace/scripts/openclaw-doctor.env` | Criar configuracao local |
| `~/.openclaw/state/doctor-state.json` | Criar estado persistente |
| `~/.openclaw/state/doctor.lock` | Criar lockfile de execucao |
| `~/.openclaw/state/pending-report.txt` | Criar fila de reenvio |
| `~/.openclaw/state/pending-report.json` | Criar fila de reenvio estruturada |
| `~/.openclaw/logs/doctor/` | Criar diretorio de logs |
| `~/.config/systemd/user/openclaw-doctor.service` | Criar unit de execucao |
| `~/.config/systemd/user/openclaw-doctor.timer` | Criar timer diario |

## Verificacao v2

1. validar sintaxe do script: `bash -n openclaw-doctor.sh`
2. validar `--dry-run` sem update nem restart reais
3. validar lock executando duas instancias em paralelo
4. validar geracao de `doctor-state.json`
5. validar criacao de relatorio `.log` e `.json`
6. simular falha de Telegram e verificar `pending-report.*`
7. simular update disponivel e confirmar restart + health check
8. simular gateway nao subir e confirmar status degradado com persistencia local
9. validar `systemd --user timer` com `systemctl --user list-timers`
10. validar reexecucao do instalador sem duplicar configuracao

## Criterio de Aceite

A v2 so deve ser considerada pronta se:

- continuar funcional sem intervencao humana diaria
- sobreviver a falha de notificacao sem perder rastreabilidade
- impedir concorrencia entre execucoes
- manter historico minimo do que ocorreu
- ser instalavel em multiplas instancias sem editar o script principal
- operar de forma previsivel mesmo quando update ou restart falharem

## Resumo Executivo

A v1 era um bom script operacional. A v2 passa a ser uma automacao autonoma de verdade:

- com memoria de execucao
- com entrega pendente e retry controlado
- com lock de concorrencia
- com politica de update explicita
- com agendamento mais robusto
- com menos acoplamento fragil a detalhes da instancia
