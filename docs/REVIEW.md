# Revisao do OpenClawNurse

## Escopo da revisao

Foi feita uma revisao completa do runtime, instalador, timer, defaults e caminho de clonagem para outra maquina.

## Problemas encontrados e tratados

### 1. Falso positivo na classificacao do `doctor`

Antes:

- qualquer output contendo `Run "openclaw doctor --fix"` podia cair em `DEGRADED`

Depois:

- a classificacao procura sinais concretos como `missing transcripts`, `failed`, `unhealthy`, `corrupt` e similares

### 2. Highlights do relatorio com lixo visual

Antes:

- linhas do `doctor` vinham com restos de box drawing como `│`

Depois:

- os highlights sao normalizados para texto simples

### 3. Falta de teste guiado para maquina nova

Antes:

- havia `--dry-run`, mas nao um caminho curto para validar instalacao e conectividade

Depois:

- existe `--self-test` para preflight, status, health e `message send --dry-run`

### 4. Documentacao insuficiente para uso em outra maquina

Antes:

- o README era curto e assumia contexto previo

Depois:

- existe cartilha dedicada com clonagem, instalacao, testes, operacao e troubleshooting

### 5. Falta de remediacao automatica para o principal problema atual

Antes:

- o runtime detectava `missing transcripts`, mas so degradava o status

Depois:

- o runtime consegue confirmar a necessidade via `sessions cleanup --dry-run --fix-missing --json`
- em execucao real, pode aplicar `sessions cleanup --enforce --fix-missing`
- apos remediar, ele reroda o `doctor` para reclassificar o estado

### 6. Falta de visibilidade sobre drift operacional

Antes:

- CLI, servico `openclaw-gateway.service` e instalacoes antigas podiam divergir sem alerta claro
- erros reais do Telegram/model provider ficavam enterrados no journal

Depois:

- o runtime registra um bloco `sanity` no JSON de estado
- detecta binarios `openclaw` com versoes diferentes
- compara versao do CLI com `Description` e `ExecStart` do gateway
- valida contratos conhecidos de config, como `channels.telegram.streaming`
- confere comandos nativos esperados no bot Telegram via `getMyCommands`
- varre o journal desde a ultima execucao para sessoes travadas, config invalida, warnings de provenance de update e erros de provider com input vazio

## Riscos ainda existentes

### 1. Parsing do `doctor` ainda e heuristico

O `openclaw doctor` nao expõe JSON atualmente. A classificacao continua dependendo de texto, embora agora esteja menos frágil.

### 2. Autodeteccao de `TELEGRAM_TARGET` e oportunista

Ela tenta descobrir o target via cron state do OpenClaw local. Em maquina nova ou perfil diferente isso pode nao existir. O caminho seguro continua sendo preencher manualmente o `.env`.

### 3. Portabilidade assumida e Linux-first

O projeto foi preparado para host Linux com `systemd --user` ou `cron`. Nao foi desenhado para macOS ou Windows.

### 4. Remediacao automatica continua conservadora

Isso e intencional. O runtime ainda nao executa limpezas agressivas de sessoes ou estado interno do OpenClaw sem uma rodada adicional de implementacao.

### 5. Hotfixes em runtime do OpenClaw nao sao aplicados automaticamente

O OpenClawNurse agora detecta sintomas como provider recebendo input vazio, mas nao patcha `node_modules`. Esse tipo de correcao deve ir para o OpenClaw upstream para nao criar uma manutencao fragil por versao.

## Conclusao

O projeto esta pronto para:

- ser clonado em outra maquina Linux com OpenClaw
- ser instalado com `./install.sh`
- ser testado com `--self-test` e `--dry-run`
- operar com scheduler autonomo

O principal limite atual nao e mais de instalacao; e de profundidade de remediacao automatica sobre problemas que o proprio `openclaw doctor` detecta.
