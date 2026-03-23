# Runbook: Scripts Refactor & Operations

## Мета

Цей runbook фіксує поетапний (ітеративний) рефакторинг скриптів у `scripts/` за принципами SOLID, з обов'язковими:
- модульністю;
- оркестрацією через основний entrypoint-скрипт;
- режимом `--dry-run`;
- можливістю запуску окремих модулів;
- перевірками після кожної ітерації.

## Загальні правила ітерацій

1. Рефакторимо **один скрипт за ітерацію**.
2. Перед змінами:
   - `git status --short --branch`
   - `docker compose ps`
3. Після змін мінімум:
   - `bash -n ...`
   - `shellcheck ...`
   - функціональний `--dry-run`
4. Після кожної ітерації оновити:
   - цей runbook;
   - активний changelog-том (`CHANGELOGS/CHANGELOG_2026_VOL_02.md`).

## Контракт для refactored скриптів

Кожен оркестратор повинен підтримувати:
- `--dry-run` — не змінює файли/інфраструктуру, лише план дій;
- `--modules a,b,c` — точковий запуск підмодулів;
- `--list-modules` — перелік доступних модулів;
- `-h|--help` — довідка.

## Ітерації

### Ітерація 1 — `scripts/patch-local.cfg.sh`

**Статус:** ✅ завершено.

**Що зроблено:**
- Скрипт перетворено на оркестратор модулів.
- Логіку винесено в:
  - `scripts/lib/patch-local/helpers.sh`
  - `scripts/lib/patch-local/env.sh`
  - `scripts/lib/patch-local/db_rotation.sh`
  - `scripts/lib/patch-local/modules.sh`
- Додано керування:
  - `--dry-run`
  - `--modules`
  - `--list-modules`

**Відповідальність:**
- Оркестратор: аргументи, порядок запуску модулів.
- `env.sh`: завантаження `.env`.
- `helpers.sh`: утиліти патчингу ключів і dry-run викликів.
- `modules.sh`: функціональні модулі конфігурації.
- `db_rotation.sh`: sync пароля ролі PostgreSQL.

**Як запускати:**
```bash
./scripts/patch-local.cfg.sh
./scripts/patch-local.cfg.sh --dry-run
./scripts/patch-local.cfg.sh --modules database,db_rotation
./scripts/patch-local.cfg.sh --list-modules
```

**Що перевірено:**
- `bash -n`
- `shellcheck`
- `--list-modules`
- `--dry-run` (повний і частковий)

### Ітерація 3 — `scripts/smoke-test.sh`

**Статус:** ✅ завершено.

**Що зроблено:**
- `scripts/smoke-test.sh` перетворено на модульний оркестратор.
- Логіку винесено в:
   - `scripts/lib/smoke-test/helpers.sh`
   - `scripts/lib/smoke-test/env.sh`
   - `scripts/lib/smoke-test/modules.sh`
- Додано керування:
   - `--dry-run`
   - `--modules`
   - `--list-modules`

**Відповідальність:**
- Оркестратор: аргументи, селекція модулів, підсумковий статус.
- `env.sh`: безпечне завантаження `.env`.
- `helpers.sh`: HTTP/header/CORS/sitemap перевірки, logging, fail/warn політика.
- `modules.sh`:
   - `context` — формує URL-контекст (`UI/API/OAI/SITEMAP`, `HOST`, `ORIGIN`);
   - `required_checks` — критичні endpoint-checks;
   - `security_headers` — обовʼязкові security headers;
   - `cors_safety` — preflight-перевірка безпечної CORS-комбінації;
   - `sitemap_optional` — warning-only sitemap перевірка.

**Як запускати:**
```bash
./scripts/smoke-test.sh
./scripts/smoke-test.sh --dry-run
./scripts/smoke-test.sh --modules required_checks,security_headers,cors_safety
./scripts/smoke-test.sh --list-modules
```

**Що перевірено:**
- `bash -n`
- `shellcheck`
- `--list-modules`
- `--dry-run` (повний і частковий)

### Ітерація 4 — `scripts/run-maintenance.sh`

**Статус:** ✅ завершено.

**Що зроблено (без ускладнень):**
- `scripts/run-maintenance.sh` залишено як простий оркестратор.
- Логіку рознесено на окремі скрипти:
   - `scripts/run-maintenance-dspace.sh` — DSpace maintenance (filter-media, index-discovery, oai import);
   - `scripts/run-maintenance-unmount.sh` — безпечне розмонтування GoogleDrive/SMB + cleanup `rclone`;
   - `scripts/run-maintenance-poweroff.sh` — вимкнення хоста.

**Відповідальність:**
- Оркестратор: завантаження `.env` + послідовний виклик 3 кроків.
- `run-maintenance-dspace.sh`: тільки maintenance-команди DSpace.
- `run-maintenance-unmount.sh`: тільки unmount/cooldown/cleanup.
- `run-maintenance-poweroff.sh`: тільки poweroff.

**Як запускати:**
```bash
./scripts/run-maintenance.sh
```

**Що перевірено:**
- `bash -n` для 4 maintenance-скриптів.
- `shellcheck` для 4 maintenance-скриптів.

### Ітерація 2 — `scripts/patch-config.yml.sh`

**Статус:** ✅ завершено.

**Що зроблено:**
- `scripts/patch-config.yml.sh` перетворено на оркестратор модулів.
- Логіку винесено в:
   - `scripts/lib/patch-config/helpers.sh`
   - `scripts/lib/patch-config/env.sh`
   - `scripts/lib/patch-config/modules.sh`
- Додано керування:
   - `--dry-run`
   - `--modules`
   - `--list-modules`

**Відповідальність:**
- Оркестратор: аргументи, порядок запуску модулів, запуск dry-run.
- `env.sh`: завантаження `.env`.
- `helpers.sh`: утиліти для preview/запису YAML.
- `modules.sh`:
   - `rest_context` — розбір `DSPACE_REST_BASEURL` у `ssl/host/port/namespace`;
   - `matomo_context` — побудова optional `headTags` для Matomo;
   - `render_config` — генерація `ui-config/config.yml`.

**Як запускати:**
```bash
./scripts/patch-config.yml.sh
./scripts/patch-config.yml.sh --dry-run
./scripts/patch-config.yml.sh --modules rest_context,matomo_context,render_config
./scripts/patch-config.yml.sh --modules render_config
./scripts/patch-config.yml.sh --list-modules
```

**Що перевірено:**
- `bash -n`
- `shellcheck`
- `--list-modules`
- `--dry-run` (повний і частковий)
