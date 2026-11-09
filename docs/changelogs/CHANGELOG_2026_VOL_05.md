## 2026-11-09 — Clarify GHCR connectivity failures

### Changed
- Clarified registry inspection errors in the upgrade script and added targeted production DNS and HTTPS diagnostics to the runbook.

### Verification
- The operator reported a TLS handshake timeout against GHCR during production preflight. GitHub's package page lists the expected UI image tag. Production network and registry access remain to be diagnosed.
- Mocked preflight failure preserved the underlying TLS diagnostic and stopped before service changes; ShellCheck and shell syntax passed.

## 2026-11-09 — Prepare DSpace 10.1 production upgrade

### Changed
- Extended the one-time Swarm upgrade for explicit production selection and confirmation, with a preflight-only mode. Before stopping services, it checks the selected environment against the database identity, PostgreSQL, Solr and assetstore mounts, and versioned secret names.
- Documented production prerequisites, operator commands, recovery boundaries and the subsequent release workflow. The encrypted production environment was not modified.

### Verification
- The operator reported successful dev admin and Integrator checks and completed production backups; backup contents and recovery were not independently checked here.
- Mocked dev and production success, confirmation and environment mismatch paths were checked locally. Production migration, deployment and end-to-end acceptance remain unverified.

## 2026-11-09 — Restore missing DSpace 10 submission forms

### Changed
- Added the upstream DSpace 10.1 `owner` and `datasetStep` forms to a versioned additions file and taught the submission form patcher to add only missing forms for DSpace 10.x.

### Verification
- The dev backend returned HTTP 400 for `discover/browses` and logged `Missing the owner form`. An isolated DSpace 10.1 instance returned HTTP 400 with the existing forms, then HTTP 200 after both missing forms were added.
- The isolated patcher check covered DSpace 9, both forms, repeat execution and the restart flag. The patch has not been applied to the dev service. The separate missing admin sidebar issue remains under investigation.
- For the affected user, database membership in `Administrator` was present; the operator observed an authenticated OIDC session and one `administratorOf` authorization. The admin sidebar element was absent. A reported CSP message was report-only and does not establish a blocking cause.
- DSpace Angular 10.1 initializes persistent menu providers together; the browse provider waits for a successful `discover/browses` response. Its HTTP 400 is a plausible cause of the missing sidebar, pending verification after applying the forms fix to dev.

## 2026-11-09 — Deploy DSpace 10.1 to dev

### Verification
- The operator reported the upgrade deployment completed; its local marker reads `deploy-complete`. Swarm reports 1/1 for DSpace 10.1 backend and Solr, the patched Angular image and PostgreSQL 15; their running containers report healthy.
- `database info` showed successful DSpace 10.0 migrations and two older migrations marked Out of Order. All six expected Solr cores reported no initialization failures; search contained 465 documents, statistics 384 and authority 0.
- Required dev smoke checks returned HTTP 200 for UI, REST core/sites and OAI Identify. Solr startup logged a StatusLogger reconfiguration error; its operational effect has not been established.
- Search correctness, PDF access, OIDC, mail delivery and end-to-end KDV/Koha acceptance remain to be verified.

## 2026-11-09 — Wait for stopped Swarm tasks during DSpace upgrade

### Changed
- Wait up to 90 seconds for each local container to stop after scaling the service to zero. Allow a guarded resume only before the search schema replacement and migration job.

### Verification
- The operator's attempt stopped after scaling Solr to zero, before creating the schema backup or migration job. The services were subsequently observed at zero replicas and the marker remained `started`.
- Mocked checks covered delayed Solr shutdown and the guarded resume; shell syntax and ShellCheck passed. A complete upgrade remains unverified.

## 2026-11-09 — Prepare automated DSpace 10.1 Swarm upgrade

### Changed
- Added a dev-only one-time Swarm upgrade script and operational runbook, including schema backup, a migration job, Discovery indexing and failure handling. Marked the operational script as deployment-neutral in the CI gate.

### Verification
- Shell syntax, ShellCheck and mocked preflight, success, retry, Solr failure and migration failure checks passed. A disposable Swarm job completed. The current search schema matched the existing image after XML whitespace normalization. The complete upgrade and recovery have not been exercised on a Swarm stack; runtime acceptance is pending.

## 2026-11-09 — Exercise KDV client against isolated DSpace 10.1

### Verification
- On a fresh isolated PostgreSQL 15 database, DSpace 10.1 `database migrate ignored` completed and `database info` showed successful 10.0 migrations.
- The actual KDV client passed authentication, item creation and metadata update, UID and handle lookup, PDF upload/download and checksum, primary bitstream creation/replacement, and deletion of the old bitstream against isolated DSpace 10.1 and Solr 10.1.
- Upgrade from coordinated data, full Integrator and Koha processing, duplicate handling, error paths and link repair remain unverified.

## 2026-11-09 — Prepare migration and compatibility rehearsal

### Changed
- Documented the ordering and stop conditions for an isolated DSpace 10.1 database migration and existing Solr search schema upgrade, and the KDV REST acceptance scenarios.

### Verification
- Reviewed the startup and Swarm deploy paths and DSpace 10.1 source tests for selected REST operations. KDV DSpace contract tests passed (22 tests); these use mocked responses.
- The complete procedure, live DSpace 10.1 REST compatibility, and an upgrade from a coordinated backup remain unverified. No deployment was performed.

## 2026-11-09 — Plan DSpace 10.1 dev upgrade

### Changed
- Added a staged DSpace 10.1 and PostgreSQL 17 DHI implementation plan, including backup, rollback, and KDV Integrator acceptance.
- Pinned the custom Angular build to the DSpace 10.1 release commit; removed the unused `DSPACE_VERSION` key from the environment contract.

### Verification
- Confirmed the 10.1 backend, Solr, and Angular tags in Docker Hub's catalog and identified the Angular release commit from GitHub.
- The existing OIDC patch applies to the 10.1 source; the dev environment contract validates and the three upstream image manifests are available.
- The custom Angular 10.1 Docker image built locally. npm reported 82 dependency vulnerabilities during the build; their applicability to the final image has not been assessed.
- The 10.1 search schema differs from 9.x, while the current Solr entrypoint preserves existing core configuration. Existing Solr data and configuration require an isolated upgrade rehearsal before deployment.
- The operator reported a successful PostgreSQL 15 restore smoke from the 2026-11-09 dev metadata backup (63 tables). An isolated restore of that SQL dump completed DSpace 10.1 `database migrate ignored`; `database info` showed the 10.0 migrations succeeded. A clean Solr 10.1 search core started separately.
- An isolated online copy of the existing Solr cores started under 10.1; replacing the search schema and reloading preserved counts (search 305, statistics 380, authority 0). A synthetic document was indexed and found using the new `itemauthoritylookup` field. This does not verify a consistent backup or full DSpace reindex.
- A separate isolated rehearsal restored the SQL dump, migrated the database, and completed `index-discovery -b`. Search document count changed from 305 to 465 and statistics remained 380; the SQL and Solr copies were not a coordinated snapshot and no assetstore was mounted, so search correctness and full-text indexing remain unverified.
- UI publication, deployment, and live integration acceptance were not performed.

## 2026-11-03 — Skip deployment for operational scripts

### Changed
- Added the requested operational scripts to the CI deploy gate's skip list. CI continues to run; deployment remains enabled when a service manifest, configuration, or other deploy relevant file changes.

### Verification
- Deploy gate decisions were checked for operational-only, service configuration, and mixed changes.

## 2026-11-03 — Restore smoke readiness and success timestamp

### Changed
- Wait for a successful SQL query against the target database before importing the dump.
- Preserve the previous success timestamp for the same metric labels when a restore smoke test fails.

### Verification
- Bash syntax, ShellCheck, and isolated success/failure metric checks passed.
- A real restore smoke test and production deployment were not performed; the reported startup race remains unconfirmed.

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
