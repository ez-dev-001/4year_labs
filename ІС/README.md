# ІС моніторингу роботи з базою даних

Система отримує дані про роботу з БД PostgreSQL, збирає метрики Prometheus, логи Loki і трейси Tempo,
показує все в Grafana. Доступ є лише в авторизованих користувачів (власний сервер авторизації на Python + SQLite).

## Архітектура

```
                 браузер
                    │  http://localhost:8080
                    ▼
               ┌─────────┐  auth_request   ┌──────────────────┐
               │  nginx  │ ──────────────► │ auth (Python +   │
               └────┬────┘   /auth/verify  │ SQLite)          │
       з сесією     │                      └──────────────────┘
          ┌─────────┴──────────┐
          ▼                    ▼
     ┌─────────┐         ┌────────────┐
     │ Grafana │         │ Prometheus │ ◄── scrape ── generator:9100, postgres-exporter:9187, auth:9100
     └────┬────┘         │   (TSDB)   │
          │ запити       └────────────┘
          ├──► Loki  ◄── Alloy ◄── stdout усіх контейнерів (docker.sock)
          └──► Tempo ◄── OTLP ◄── generator, auth

  generator (Python) ──SQL──► PostgreSQL ◄── postgres-exporter
```

## Відповідність пунктам завдання

| № | Пункт | Реалізація |
|---|-------|-----------|
| 0 | СУБД у Docker | `postgres` (PostgreSQL 16), БД `shop`, порт `127.0.0.1:5433` для DBeaver/pgAdmin |
| 1 | Генерація й актуалізація даних | `app/generator.py`: кожні 2 с реєструє клієнтів, створює замовлення, змінює статуси (new → paid → shipped), будує звіт, видаляє старі замовлення |
| 2 | Збір даних | Prometheus опитує генератор (`db_operations_total`, `db_operation_seconds`, `shop_orders`), `postgres-exporter` (`pg_stat_database_*`, `pg_database_size_bytes`) і сервер авторизації (`auth_logins_total`) |
| 3 | Time Series Storage | вбудована TSDB Prometheus, том `prometheus-data`, зберігання 7 днів |
| 4 | Відображення | Grafana, дашборд «ІС: моніторинг роботи з БД» відкривається одразу після входу |
| 5 | Логи (Loki) | Grafana Alloy читає stdout усіх контейнерів проєкту і передає в Loki з міткою `service` |
| 6 | Трейси (Tempo) | OpenTelemetry: один цикл генератора = трейс `shop_cycle`, кожен SQL-запит = span; вхід користувача = трейс `login` |
| 7 | Авторизація | `app/auth.py`: користувачі й сесії в SQLite, паролі PBKDF2-SHA256 із сіллю, сесійний cookie HttpOnly на 8 год. nginx пропускає до Grafana і Prometheus лише запити з валідною сесією, Grafana довіряє імені користувача з nginx (auth proxy) |
| 8 | Контейнеризація | усе в `docker-compose.yml`, 10 контейнерів |
| 9 | Брокер повідомлень | не використано (завдання це дозволяє), замість нього моніторинг СУБД через `postgres-exporter` |

## Запуск

Потрібен Docker Desktop (Windows/macOS) або Docker Engine + Compose (Linux).

```bash
docker compose up -d --build
```

Через ~30 с відкрийте http://localhost:8080 і увійдіть: **admin / admin123**.

| Адреса | Що там |
|--------|--------|
| http://localhost:8080 | Grafana з дашбордом |
| http://localhost:8080/prometheus/ | інтерфейс Prometheus (Status → Targets: усі цілі `UP`) |
| http://localhost:8080/auth/logout | вихід |

Без входу будь-яка адреса перенаправляє на сторінку логіну. Grafana і Prometheus не мають опублікованих портів, тож обійти nginx неможливо.

Додати користувача (пароль запитає консоль):

```bash
docker compose exec auth python auth.py adduser ivan
```

Зупинити: `docker compose down`. Видалити ще й усі дані: `docker compose down -v`.

## Що показати на захисті

**Дашборд** (Grafana → Dashboards → ІС): кількість замовлень, SQL-операцій за секунду, помилки, розмір БД,
операції за типом, час виконання p95, замовлення за статусом, зміни рядків і транзакції в PostgreSQL,
з'єднання, спроби входу, живі логи й останні трейси.

**Логи** (Explore → Loki):

```logql
{service="generator"} |= "failed"              # помилки SQL (дублікати email -> UniqueViolation)
{service="auth"} |= "login"                    # успішні й невдалі входи
{service="postgres"}                           # лог самої СУБД
sum by (service) (count_over_time({service=~".+"}[1m]))   # потік логів за сервісами
```

Біля кожного рядка з `trace_id` є кнопка **Tempo**, вона відкриває трейс цього циклу.

**Трейси** (Explore → Tempo → TraceQL):

```traceql
{resource.service.name="generator" && status=error}   # цикли з помилкою SQL
{name="create_order" && duration > 5ms}               # повільні вставки
{resource.service.name="auth"}                        # входи користувачів
```

Зі span'а кнопка **Logs for this span** веде назад у логи Loki.

**Prometheus** (Explore → Prometheus):

```promql
sum by (op) (rate(db_operations_total[1m]))
histogram_quantile(0.95, sum by (op, le) (rate(db_operation_seconds_bucket[1m])))
rate(pg_stat_database_xact_rollback{datname="shop"}[1m])
```

**База** (DBeaver: `localhost:5433`, БД/користувач/пароль `shop`):

```sql
SELECT status, count(*), sum(amount) FROM orders GROUP BY status;
```

## Структура

```
docker-compose.yml           усі сервіси
app/                         один Python-образ для двох сервісів
  generator.py               генератор даних + метрики/логи/трейси
  auth.py                    сервер авторизації (SQLite)
  obs.py                     спільне налаштування логів і трейсів
  test_auth.py               самоперевірка авторизації
nginx/nginx.conf             єдиний вхід, перевірка сесії
prometheus/prometheus.yml    цілі збору метрик
alloy/config.alloy           збір логів контейнерів -> Loki
tempo/tempo.yaml             прийом трейсів OTLP
grafana/provisioning/        джерела даних і підключення дашборда
grafana/dashboards/db.json   дашборд
```

Тести авторизації: `docker compose exec auth python -m unittest test_auth`.
