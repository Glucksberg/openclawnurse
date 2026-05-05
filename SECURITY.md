# Security

OpenClawNurse is a local maintenance tool. It may read OpenClaw config files and Telegram credentials at runtime, but those values should never be committed to this repository.

## Do Not Commit

- `~/.config/openclawnurse/openclawnurse.env`
- `~/.openclaw/openclaw.json`
- Telegram bot tokens
- GitHub tokens
- OpenAI or provider API keys
- SSH keys, PEM files, certificates or private local state

Use placeholders in documentation and tests.

## Reporting Issues

If you find a security issue, avoid posting secrets or exploit details in a public issue. Use GitHub's private vulnerability reporting flow when available, or contact the repository owner privately.

## Maintainer Checklist Before Public Releases

```bash
git grep -nI -E '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|[0-9]{6,}:[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC |DSA |)?PRIVATE KEY-----)' HEAD -- . || true
git rev-list --all | while read rev; do
  git grep -nI -E '(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|[0-9]{6,}:[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC |DSA |)?PRIVATE KEY-----)' "$rev" -- . || true
done
```
