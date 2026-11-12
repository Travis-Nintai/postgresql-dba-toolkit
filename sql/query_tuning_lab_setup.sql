-- query_tuning_lab_setup.sql
--
-- Purpose: Build the lab data used by docs/explain-analyze-tuning.md.
--          Creates two fictional tables in the connected database,
--          lab_orders and lab_order_items, and loads them with generated
--          rows. The tables start with only their primary keys indexed,
--          which is what makes the tuning examples work: the queries in
--          the guide run slowly first, then fast after the indexes the
--          guide adds. This script WRITES data; it is a lab setup script,
--          not a read-only diagnostic. Run it once per lab database.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d labdb \
--                 -v lab_rows=100000 \
--                 -f sql/query_tuning_lab_setup.sql
--
--          lab_rows is optional and defaults to 100000 orders with three
--          line items each. The script drops the lab tables first, so it
--          is safe to re-run in the same database. Do not run it in a
--          database that already has tables named lab_orders or
--          lab_order_items: the DROP TABLE at the top removes them.
--
--          The data is fictional and generated with a fixed random seed,
--          so repeated runs produce the same distribution: 5,000
--          customers, order dates spread across 2025, five order
--          statuses, and amounts between 10.00 and 500.00.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04. See
--          docs/explain-analyze-tuning.md for the lab results.

\pset border 2
\pset null '(null)'

-- Configurable size. A default applies only when the variable was not
-- passed on the command line (psql -v), so -v always wins.
\if :{?lab_rows}
\else
\set lab_rows 100000
\endif

-- Fixed seed so the lab data is the same every run. DO keeps the
-- call quiet: setseed returns void and psql would print an empty box.
DO $$ BEGIN PERFORM setseed(0.42); END $$;

\echo '=== Dropping any previous lab tables ==='
DROP TABLE IF EXISTS lab_order_items;
DROP TABLE IF EXISTS lab_orders;

\echo '=== Creating lab_orders ==='
CREATE TABLE lab_orders (
    order_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL,
    order_date  timestamptz NOT NULL,
    status      text NOT NULL,
    amount      numeric(10,2) NOT NULL
);

\echo '=== Loading lab_orders ==='
INSERT INTO lab_orders (customer_id, order_date, status, amount)
SELECT
    1 + floor(random() * 5000)::int,
    timestamptz '2025-01-01 00:00:00+00'
        + random() * interval '365 days',
    (ARRAY['pending', 'paid', 'shipped', 'delivered', 'cancelled'])
        [1 + floor(random() * 5)::int],
    round((random() * 490 + 10)::numeric, 2)
FROM generate_series(1, :lab_rows) AS g;

\echo '=== Creating lab_order_items ==='
CREATE TABLE lab_order_items (
    item_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    bigint NOT NULL REFERENCES lab_orders (order_id),
    product_sku text NOT NULL,
    qty         integer NOT NULL,
    unit_price  numeric(10,2) NOT NULL
);

\echo '=== Loading lab_order_items (three per order) ==='
INSERT INTO lab_order_items (order_id, product_sku, qty, unit_price)
SELECT
    o.g,
    'SKU-' || lpad((floor(random() * 500))::int::text, 4, '0'),
    1 + floor(random() * 5)::int,
    round((random() * 190 + 5)::numeric, 2)
FROM generate_series(1, :lab_rows) AS o(g),
     generate_series(1, 3) AS it;

\echo '=== Analyzing the lab tables ==='
ANALYZE lab_orders;
ANALYZE lab_order_items;

\echo '=== Lab tables loaded ==='
SELECT 'lab_orders' AS table_name, count(*) AS rows,
       min(order_date) AS earliest_order,
       max(order_date) AS latest_order
FROM lab_orders
UNION ALL
SELECT 'lab_order_items', count(*), NULL, NULL
FROM lab_order_items;
