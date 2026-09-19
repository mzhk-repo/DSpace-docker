## 2026-09-19 — Генерація thumbnail для item без обкладинки

### Зроблено
- Додано `scripts/generate-item-thumbnail.sh` для обробки одного item за handle або UUID.
- Wrapper запускає штатний DSpace `PDFBox JPEG Thumbnail` для першої сторінки PDF у `ORIGINAL` bundle.
- Додано `--dry-run`, інтерактивне підтвердження, `--yes`, перевірку identifier і Swarm/Compose runtime.
- Скрипт не використовує `-f`, REST, SQL, нові секрети або прямі операції з assetstore.
- `docs/scripts_runbook.md` доповнено manual execution.

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
