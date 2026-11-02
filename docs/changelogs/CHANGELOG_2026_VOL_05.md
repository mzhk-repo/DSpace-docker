## 2026-11-02 — DSpace login token and idle timeout

## 2026-11-02 — Force supported SMTP AUTH mechanism

### Context
- SMTP2Graph advertises `AUTH LOGIN PLAIN`, but an isolated AUTH probe showed `LOGIN` is rejected while `PLAIN` succeeds with the configured credentials.

### Change
- Configured DSpace JavaMail to use SMTP AUTH `PLAIN` explicitly, avoiding selection of the gateway's unsupported `LOGIN` mechanism.

### Verification
- DNS resolution, SMTP greeting, STARTTLS certificate/hostname validation, and SMTP AUTH `PLAIN` passed from the running DSpace container; no message was submitted.
- `bash -n scripts/lib/patch-local/modules.sh` and `git diff --check` passed.

### Risks
- The new setting is not active in the running DSpace service until its config is regenerated and the service restarted. No runtime config or service was changed.

### Rollback
- Remove `mail.smtp.auth.mechanisms=PLAIN` from `mail.extraproperties`.

## 2026-11-02 — Separate SMTP login and sender address

### Changed
- Added `DSPACE_MAIL_FROM` for the DSpace sender address, separate from SMTP AUTH username. It defaults to `DSPACE_MAIL_USERNAME` for compatibility and should match the relay sender allowlist.
- Added the gateway's configured sender address to both encrypted environment contracts.
- Documented the SMTP env variable roles in the scripts runbook.

### Verification
- `bash -n scripts/lib/patch-local/modules.sh` and `git diff --check` passed.
- Runtime mail delivery was not performed.

### Risks
- Runtime mail delivery still requires verification in dev; production was not deployed or changed at runtime.

### Rollback
- Remove `DSPACE_MAIL_FROM` from `.env.example`, revert the email patcher fallback, and remove the runbook note.

### Changed
- Set the DSpace login JWT lifetime to 24 hours for all authentication methods.
- Configure the UI idle warning after 23 hours 55 minutes and logout after a further 5 minutes. Active sessions may refresh their JWT.
- Documented the session behavior and longer-lived token risk in the configuration runbook.

### Verified
- `bash -n` and `shellcheck` passed for the modified modules and their entry scripts.
- Isolated generation confirmed the JWT setting is idempotent and the generated UI YAML contains the expected idle settings.

### Pending
- OIDC return-page behavior, actual JWT lifetime, and UI idle behavior require dev runtime verification. No browser or authenticated dev session was available; the redirect cause and any configuration-only fix remain unconfirmed.
- No deployment or runtime change was performed. A longer-lived stolen token may remain usable longer.

## 2026-09-19 — CI deploy gate shell syntax hotfix

### Виправлено
- У `.github/workflows/main.yml` додано явне shell-продовження рядків у багаторядковому `case` для списку operational-only paths.
- Усунуто `syntax error near unexpected token 'newline'` у GitHub Actions runner.

### Перевірено
- Bash syntax для deploy-change-check `case` block — OK.
- Workflow YAML parse — OK.
- `git diff --check -- .github/workflows/main.yml` — OK.

## 2026-09-19 — Генерація thumbnail для item без обкладинки

### Зроблено
- `scripts/generate-item-thumbnail.sh` розширено режимом `--all` для обробки всіх items без generated thumbnail.
- Wrapper запускає штатний DSpace `PDFBox JPEG Thumbnail` для першої сторінки PDF у `ORIGINAL` bundle.
- Режим `--all` не потребує `--yes` і придатний для systemd timer; одиночний item зберігає інтерактивне підтвердження.
- Збережено `--dry-run`, `--yes`, перевірку identifier і Swarm/Compose runtime.
- Скрипт не використовує `-f`, REST, SQL, нові секрети або прямі операції з assetstore.
- `docs/scripts_runbook.md` доповнено manual execution.
- У `.github/workflows/main.yml` додано `deploy-change-check`: operational-only scripts запускають CI без CD, а deploy/startup/payload/patch-зміни зберігають звичайний deploy-контур.

### Перевірено
- `bash -n scripts/generate-item-thumbnail.sh` — OK.
- `shellcheck scripts/generate-item-thumbnail.sh` — OK.
- `bash scripts/generate-item-thumbnail.sh --help` — OK.
- `bash scripts/generate-item-thumbnail.sh --env dev --item 123456789/42 --dry-run` — OK.
- `bash scripts/generate-item-thumbnail.sh --env dev --item 00000000-0000-4000-8000-000000000000 --dry-run` — OK.
- Runtime generation у dev/prod не виконувався.

### Data/impact
- Зміни DSpace item, assetstore або production runtime не виконувались.

## 2026-05-11 — Assetstore orphan cleanup wrapper

### Зроблено
- Додано `scripts/cleanup-assetstore-orphans.sh` для запуску штатного DSpace cleanup через `/dspace/bin/dspace cleanup --verbose`.
- Скрипт використовує існуючий autonomous env-loading (`--env dev|prod` / `SERVER_ENV`) і Swarm-aware runtime helper `scripts/lib/docker-runtime.sh`.
- Додано `--dry-run`, який друкує команду без змін в assetstore.
- `docs/scripts_runbook.md` доповнено manual execution для cleanup-скрипта.

### Перевірено
- `bash -n scripts/cleanup-assetstore-orphans.sh` — OK.
- `shellcheck scripts/cleanup-assetstore-orphans.sh` — OK.
- `bash scripts/cleanup-assetstore-orphans.sh --env prod --dry-run` — OK, mutation не виконувалась.
- `bash scripts/cleanup-assetstore-orphans.sh --env prod` — OK; DSpace cleanup завершився без крешів, знайдено `0` deleted bitstream.

### Data/impact
- Реальний cleanup виконано в prod-контексті штатною командою DSpace; orphan/deleted bitstreams для видалення не знайдено.
