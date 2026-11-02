## 2026-11-02 — Resolve Angular image Hadolint findings

### Changed
- Pinned PM2 to `7.1.1` and specified the Node image's numeric user and group IDs (`1000:1000`).
- Scoped the Alpine package version lint exception to the build dependencies; their versions continue to follow the floating base image.

### Verified
- Hadolint `v2.15.1` passed for `ui/Dockerfile`.
- The Dockerfile change generates a new UI image reference; rebuilding and runtime verification remain pending.

## 2026-11-02 — Fix Angular image GHCR namespace and preserve build cache

### Changed
- Corrected the Angular image namespace to the repository owner's `mzhk-repo` GHCR namespace and added a CI owner check before building.
- Added a Buildx cache exported before the image is published, allowing later runs to reuse a successful build even if publishing fails.

### Context
- CI run `41440206025` built the image but failed to publish it under `pinokew`; the GitHub repository owner is `mzhk-repo`.
- The package publication and Swarm pull have not yet been verified with the corrected namespace.

## 2026-11-02 — Correct SMTP authentication diagnosis

### Context
- A corrected SMTP probe confirmed both `LOGIN` and `PLAIN` authentication succeed. The earlier `LOGIN` probe supplied an unintended empty response and produced a misleading rejection.
- The DSpace log records HTTP 403 `Password reset is not allowed!`; the active configuration sets `user.forgot-password = false`.

### Change
- Removed the forced `PLAIN` mechanism to restore JavaMail's normal mechanism selection.
- Made local password reset configurable with `DSPACE_USER_FORGOT_PASSWORD` (default `false`) and enabled it in the development environment contract after user approval.

### Verification
- The SMTP authentication probes were performed over validated STARTTLS from the running DSpace container, without submitting a message.
- The password reset setting and error were observed in the running DSpace configuration and log.
- The security module generated `false` by default and `true` when explicitly configured; both encrypted environment contracts passed `verify-env.sh --all`.
- The dev backend configuration was regenerated and its service restart initiated; the replacement container reports `user.forgot-password = true`.

### Risks
- Enabling password reset allows local DSpace accounts to request password reset links. Mail delivery has not been verified.

## 2026-11-02 — Force supported SMTP AUTH mechanism

### Context
- Correction: the original `LOGIN` probe was malformed; a subsequent corrected probe succeeded. See the later SMTP authentication diagnosis entry.

### Change
- Configured DSpace JavaMail to use SMTP AUTH `PLAIN` explicitly, based on the incorrect inference that `LOGIN` was unsupported.

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

## 2026-11-02 — Persistent Angular OIDC return-page patch

### Changed
- Added an Angular source patch that saves the current route before OIDC login and a Dockerfile based on a pinned upstream commit.
- CI builds the patched UI and publishes it to GHCR on dev pushes and releases; Swarm deploys the content-derived image reference after checking registry access.
- Corrected the deploy gate so operational-only changes skip deployment and other changes permit it.
- Added a build-time patch applicability check and documented the update procedure.

### Verified
- The patch applies to the pinned DSpace Angular source.
- Shell syntax and ShellCheck passed for the image reference and Swarm orchestration scripts; workflow YAML and image substitution were checked.
- The deploy gate was checked with operational-only, UI, and mixed changes.

### Pending
- The image has not been built or deployed. GHCR access and a complete OIDC runtime check in dev are required before the patch is accepted.

## 2026-11-02 — DSpace login token and idle timeout

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
