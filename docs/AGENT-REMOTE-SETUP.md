# Prompt Pronto Para Enviar ao Agente OpenClaw da VPS

Copie e cole a mensagem abaixo para o agente OpenClaw da instancia remota.

```text
Voce esta nesta VPS para instalar e configurar o OpenClawNurse desta instancia.

Objetivo:
1. instalar o openclawnurse nesta VPS
2. configurar o nurse corretamente para esta instancia isolada
3. validar o setup
4. me devolver um relatorio final objetivo
5. se algum passo depender de mim, me dizer exatamente qual comando eu preciso rodar ou qual valor eu preciso fornecer

Contexto operacional:
- esta VPS e independente
- esta VPS tem seu proprio OpenClaw
- esta VPS manda relatorio para seu proprio grupo de Telegram
- nao quero configurar fleet, host central ou integracao entre servidores agora
- se existir documentacao de fleet no repo, ignore por enquanto
- foque apenas na instalacao e operacao isolada do nurse nesta VPS

Repositorio esperado:
- ~/openclawnurse

Fluxo que voce deve executar:
1. verificar se openclaw, jq, systemd --user ou cron, e o supervisor do gateway estao disponiveis
2. clonar o repo do openclawnurse em ~/openclawnurse se ainda nao existir
3. rodar ./install.sh
4. revisar ~/.config/openclawnurse/openclawnurse.env
5. configurar o restart do gateway de acordo com o host
6. configurar o TELEGRAM_TARGET correto, se ele puder ser detectado; se nao puder, me pedir o valor exato
7. rodar self-test
8. rodar dry-run sem notificacao
9. confirmar se openclawnurse.timer ficou ativo; se systemd --user nao funcionar, configurar cron
10. me devolver um relatorio final

Criterios de aceite:
- openclawnurse instalado em ~/.local/share/openclawnurse
- config presente em ~/.config/openclawnurse/openclawnurse.env
- self-test concluido
- dry-run concluido
- timer ou cron configurado
- estado final explicado com clareza

Formato da sua resposta final:
- Status geral: OK ou PENDENTE
- O que foi instalado
- O que foi configurado
- Resultado do self-test
- Resultado do dry-run
- Como o agendamento ficou
- Qual arquivo de config ficou valendo
- Se falta algo meu: listar em bullets curtos e concretos

Se precisar de algum valor meu, nao seja vago.
Diga exatamente um destes formatos:
- "Me envie o TELEGRAM_TARGET desta VPS"
- "Rode este comando e me mande a saida: <comando>"
- "Preciso que voce confirme se o gateway desta VPS e gerenciado por pm2 ou systemd"
```
