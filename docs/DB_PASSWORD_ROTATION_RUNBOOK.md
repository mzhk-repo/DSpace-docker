# Runbook: Ротація пароля БД (PostgreSQL) для DSpace

## Мета

Безпечно змінити пароль PostgreSQL через `.env` так, щоб:
- `dspace/config/local.cfg` синхронізувався автоматично;
- пароль ролі в БД оновився автоматично;
- уникнути аварійного `unhealthy/restarting` стану `dspace` через розсинхрон паролів.

> Поточна автоматизація виконується в `scripts/patch-local.cfg.sh`.

---

## Важливо про "без простою"

- Для **PostgreSQL** ротація виконується без зупинки БД.
- Для **DSpace backend** у single-instance режимі можливий короткий blip під час перезапуску застосунку.
- Для strict zero-downtime API потрібна схема з 2+ backend-інстансами за reverse proxy.

---

## Передумови

1. Є доступ до хоста з Docker.
2. Запущені сервіси `dspacedb` і `dspace`.
3. У репозиторії присутній `.env`.
4. Виконується з кореня репозиторію `DSpace-docker`.

Перевірка:

```bash
docker compose ps
```

---

## Автоматизована процедура ротації

### 1) Онови пароль у `.env`

Зміни значення `POSTGRES_PASSWORD` на новий секрет.

### 2) Запусти синхронізацію конфігу + ролі БД

```bash
./scripts/patch-local.cfg.sh
```

Що робить скрипт автоматично:
- оновлює `db.password` у `dspace/config/local.cfg`;
- підключається до контейнера БД (`dspacedb`);
- виконує `ALTER ROLE <POSTGRES_USER> WITH PASSWORD <POSTGRES_PASSWORD>`;
- завершується помилкою, якщо синхронізація ролі не вдалася (за замовчуванням).

### 3) Перезапусти тільки backend (рекомендовано)

```bash
docker compose up -d dspace
```

### 4) Перевір health

```bash
docker compose ps dspace
docker logs --tail=120 dspace
```

Очікування:
- `dspace` у стані `Up (... healthy)`;
- у логах є `Running DB migrations...` та `Starting DSpace REST...` без `password authentication failed`.

---

## Тюнінг поведінки автоматизації

Підтримані env-прапори (читаються `scripts/patch-local.cfg.sh`):

- `DB_PASSWORD_ROTATION_ENABLED=true|false` (default: `true`)
	- `false` — не змінювати пароль ролі в БД автоматично.

- `DB_PASSWORD_ROTATION_FAIL_ON_ERROR=true|false` (default: `true`)
	- `true` — падати, якщо sync ролі не вдався (безпечний режим).
	- `false` — логувати warning і продовжувати.

- `DB_CONTAINER_NAME` (default: `dspacedb`)
	- імʼя контейнера PostgreSQL.

---

## Rollback (якщо після ротації проблеми)

1. Поверни попередній `POSTGRES_PASSWORD` у `.env`.
2. Запусти:

```bash
./scripts/patch-local.cfg.sh
docker compose up -d dspace
```

3. Перевір:

```bash
docker compose ps dspace
docker logs --tail=120 dspace
```

---

## Типова помилка

`FATAL: password authentication failed for user "dspace"`

Це означає розсинхрон між:
- фактичним паролем ролі у PostgreSQL volume,
- `POSTGRES_PASSWORD` у `.env`,
- `db.password` у `dspace/config/local.cfg`.

Лікування: повторно виконати автоматизовану процедуру вище.
