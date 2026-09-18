-- db_health_check.sql
--
-- Purpose: Quick operational health check for a PostgreSQL instance.
--          Reports version and uptime, connection utilization, database sizes,
--          long-running transactions, replication status, and autovacuum
--          activity. Read-only; issues no writes.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d postgres \
--                 -v warn_conn_pct=80 -v long_txn_min=5 \
--                 -f sql/db_health_check.sql
--
--          All -v variables are optional. Defaults are set below.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04.

\pset border 2
\pset null '(null)'

-- Configurable thresholds. Defaults apply only when the variable was not
-- passed on the command line (psql -v), so -v always wins.
\if :{?warn_conn_pct}
\else
\set warn_conn_pct 80
\endif
\if :{?long_txn_min}
\else
\set long_txn_min 5
\endif

\echo ''
\echo '=== 1. Instance ==='
SELECT version() AS postgresql_version,
       now() - pg_postmaster_start_time() AS uptime;

\echo ''
\echo '=== 2. Connection utilization ==='
SELECT current_connections,
       max_connections,
       used_pct,
       active,
       idle_in_transaction,
       CASE WHEN used_pct >= :warn_conn_pct THEN 'WARNING: over threshold'
            ELSE 'OK' END AS status
FROM (
  SELECT count(*) AS current_connections,
         (SELECT setting::int FROM pg_settings WHERE name = 'max_connections')
           AS max_connections,
         round(100.0 * count(*) /
               (SELECT setting::int FROM pg_settings WHERE name = 'max_connections'), 1)
               AS used_pct,
         count(*) FILTER (WHERE state = 'active') AS active,
         count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction
  FROM pg_stat_activity
) AS conn;

\echo ''
\echo '=== 3. Database sizes ==='
SELECT datname AS database,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
WHERE datistemplate = false
ORDER BY pg_database_size(datname) DESC;

\echo ''
\echo === 4. Long-running transactions over :long_txn_min minutes ===
SELECT pid,
       usename,
       state,
       now() - xact_start AS transaction_age,
       now() - query_start AS query_age,
       left(query, 80) AS query_truncated
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND now() - xact_start > make_interval(mins => :long_txn_min)
  AND pid <> pg_backend_pid()
ORDER BY xact_start;

\echo ''
\echo '=== 5a. Replication: connected standbys (primary side; empty when none) ==='
SELECT client_addr,
       usename,
       application_name,
       state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint) AS replay_lag
FROM pg_stat_replication;

\echo ''
\echo '=== 5b. Replication: recovery state (replica side) ==='
SELECT pg_is_in_recovery() AS in_recovery,
       CASE WHEN pg_is_in_recovery()
            THEN pg_size_pretty(
                   pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                                   pg_last_wal_replay_lsn())::bigint)
            ELSE 'n/a - this instance is a primary' END AS replay_lag;

\echo ''
\echo '=== 6. Autovacuum ==='
SELECT count(*) FILTER (WHERE backend_type = 'autovacuum worker') AS autovacuum_workers,
       (SELECT count(*) FROM pg_stat_user_tables
         WHERE n_dead_tup > 1000) AS tables_with_dead_tuples_over_1000
FROM pg_stat_activity;

\echo ''
\echo 'Health check complete.'
