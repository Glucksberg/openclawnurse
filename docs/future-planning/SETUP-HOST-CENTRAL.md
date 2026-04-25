# Planejamento Futuro: Setup Rapido de Host Central

Conteudo preservado do fluxo antigo de host central.

Use este bloco em um servidor separado que vai agregar todos os nodes e publicar o dashboard.

## 1. Baixar e instalar

```bash
cd "$HOME"
git clone https://github.com/Glucksberg/openclawnurse.git
cd openclawnurse
./install.sh --skip-dry-run
```

## 2. Criar o arquivo de nodes

Crie `~/.config/openclawnurse/fleet-nodes.json` e configure os `feedUrl` dos nodes.
