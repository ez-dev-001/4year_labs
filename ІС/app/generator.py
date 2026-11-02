"""Генератор даних: імітує роботу інтернет-магазину з PostgreSQL.
Один цикл = один трейс; кожна SQL-операція = span + метрики Prometheus + рядок логу."""
import os
import random
import time

import psycopg
from opentelemetry.trace import StatusCode
from prometheus_client import Counter, Gauge, Histogram, start_http_server

from obs import setup

tracer, log = setup("generator")

OPS = Counter("db_operations_total", "SQL-операції генератора", ["op", "status"])
LATENCY = Histogram("db_operation_seconds", "Тривалість SQL-операції, с", ["op"])
ORDERS = Gauge("shop_orders", "Кількість замовлень у БД за статусом", ["status"])

SCHEMA = """
CREATE TABLE IF NOT EXISTS customers (
    id    SERIAL PRIMARY KEY,
    name  TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(id),
    amount      NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    status      TEXT NOT NULL DEFAULT 'new',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""


def run(conn, op, sql, params=()):
    """Виконує один запит, рахує метрики, пише лог і span. Помилку SQL не пробрасує, обрив з'єднання - пробрасує."""
    with tracer.start_as_current_span(op, attributes={"db.system": "postgresql", "db.statement": sql}) as span:
        start = time.perf_counter()
        try:
            with conn.cursor() as cur:
                cur.execute(sql, params)
                result = cur.fetchall() if cur.description else cur.rowcount
            conn.commit()
            OPS.labels(op, "ok").inc()
            log.info(f"{op} ok rows={len(result) if isinstance(result, list) else result}")
            return result
        except psycopg.Error as e:
            if conn.broken:
                raise
            conn.rollback()
            OPS.labels(op, "error").inc()
            span.record_exception(e)
            span.set_status(StatusCode.ERROR, type(e).__name__)
            log.error(f"{op} failed error={type(e).__name__}")
        finally:
            LATENCY.labels(op).observe(time.perf_counter() - start)


def cycle(conn):
    with tracer.start_as_current_span("shop_cycle"):
        if random.random() < 0.5:
            # email з обмеженого діапазону: з часом трапляються дублікати -> справжні помилки UNIQUE у логах і трейсах
            n = random.randint(1, 300)
            run(conn, "register_customer", "INSERT INTO customers (name, email) VALUES (%s, %s)",
                (f"Клієнт {n}", f"user{n}@example.com"))
        for _ in range(random.randint(1, 5)):
            run(conn, "create_order",
                "INSERT INTO orders (customer_id, amount) SELECT id, %s FROM customers ORDER BY random() LIMIT 1",
                (round(random.uniform(50, 5000), 2),))
        run(conn, "advance_status",
            "UPDATE orders SET status = CASE status WHEN 'new' THEN 'paid' ELSE 'shipped' END "
            "WHERE id IN (SELECT id FROM orders WHERE status <> 'shipped' ORDER BY random() LIMIT 4)")
        counts = dict(run(conn, "report", "SELECT status, count(*) FROM orders GROUP BY status") or [])
        for status in ("new", "paid", "shipped"):
            ORDERS.labels(status).set(counts.get(status, 0))
        run(conn, "cleanup",
            "DELETE FROM orders WHERE status = 'shipped' AND created_at < now() - interval '10 minutes'")


def main():
    start_http_server(9100)
    interval = float(os.getenv("INTERVAL", "2"))
    while True:
        try:
            with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
                conn.execute(SCHEMA)
                conn.commit()
                log.info("connected to database")
                while True:
                    cycle(conn)
                    time.sleep(interval)
        except psycopg.OperationalError as e:
            log.error(f"database unavailable error={type(e).__name__}, retry in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
