# Cartilha do OpenClawNurse

## O que ele faz

O OpenClawNurse e um executor autonomo para manutencao de instancias OpenClaw. Ele:

- verifica se ha update disponivel
- aplica update quando permitido pela configuracao
- executa `openclaw doctor`
- reinicia o gateway quando necessario
- confirma o health do servico
- gera relatorio local estruturado
- envia relatorio via Telegram quando configurado

## Requisitos

Antes de instalar em outra maquina:

- `openclaw` precisa estar instalado e funcional
- a maquina precisa conseguir executar `openclaw health --json`
- `jq`, `flock`, `timeout` e `sed` precisam existir
- para modo padrao, `systemd --user` precisa estar funcionando
- se nao houver `systemd --user`, use fallback com `cron`

## Fluxo recomendado em uma maquina nova

1. Clonar o repositorio.
2. Rodar a instalacao.
3. Ajustar a configuracao local.
4. Rodar um `self-test`.
5. Rodar um `dry-run`.
6. Habilitar notificacao real se o target do Telegram estiver correto.

## Clonagem

```bash
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
```

## Instalacao

Modo padrao:

```bash
./install.sh
```

Forcando `cron`:

```bash
./install.sh --scheduler cron
```

Mudando o horario do `systemd --user timer`:

```bash
./install.sh --on-calendar "*-*-* 06:00:00"
```

Sem habilitar o scheduler ainda:

```bash
./install.sh --skip-enable
```

## Onde cada coisa fica

- runtime instalado: `~/.local/share/openclawnurse`
- configuracao: `~/.config/openclawnurse/openclawnurse.env`
- estado: `~/.local/state/openclawnurse`
- logs: `~/.local/state/openclawnurse/logs`
- unit files: `~/.config/systemd/user/openclawnurse.*`

## Configuracao minima

Arquivo:

- `~/.config/openclawnurse/openclawnurse.env`

Campos mais importantes:

```bash
TELEGRAM_TARGET="-100xxxxxxxxxx"
REPORT_CHANNEL="telegram"
AUTO_UPDATE="true"
UPDATE_CHANNEL="stable"
RESTART_MODE="systemd_user"
SYSTEMD_UNIT_NAME="openclaw-gateway.service"
TIMEZONE="America/Sao_Paulo"
```

## Como testar sem risco

Teste estrutural da instalacao:

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --config ~/.config/openclawnurse/openclawnurse.env --self-test
```

Teste operacional sem update/restart reais:

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --config ~/.config/openclawnurse/openclawnurse.env --dry-run --no-notify
```

Teste de fila de pendencias:

```bash
~/.local/share/openclawnurse/bin/openclaw-doctor.sh --config ~/.config/openclawnurse/openclawnurse.env --retry-pending
```

## Operacao do dia a dia

Ver status do timer:

```bash
systemctl --user status openclawnurse.timer --no-pager
```

Ver ultima execucao:

```bash
systemctl --user status openclawnurse.service --no-pager
```

Ver logs:

```bash
journalctl --user -u openclawnurse.service -n 200 --no-pager
tail -n 200 ~/.local/state/openclawnurse/logs/doctor-*.log
```

Ver ultimo estado estruturado:

```bash
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

## Atualizacao do proprio OpenClawNurse

Quando o repositório for atualizado:

```bash
cd openclawnurse
git pull
./install.sh
```

Isso reaplica scripts e units de forma idempotente.
