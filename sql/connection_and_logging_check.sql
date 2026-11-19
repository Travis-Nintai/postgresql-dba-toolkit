-- connection_and_logging_check.sql
--
-- Purpose: Connection management and logging review for a PostgreSQL
--          instance. Reports connection utilization against
--          max_connections, connections by database, user, application,
--          state, and backend type, sessions sitting idle in a
--          transaction or idle for a long time, long-running active
--          queries, per-database connection limits, and the connection
--          and logging settings in effect for the current session.
--          Read-only; issues no writes and never terminates a session.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d <database> \
--                 -v warn_conn_pct=80 \
--                 -v warn_idle_in_txn_min=10 \
--                 -v warn_idle_min=60 \
--                 -v warn_active_min=5 \
--                 -f sql/connection_and_logging_check.sql
--
--          All -v variables are optional. The defaults are set below.
--          A connection utilization at or above warn_conn_pct is
--          flagged WARNING, as is an idle-in-transaction session older
--          than warn_idle_in_txn_min minutes. The flag is a prompt to
--          look at the sessions responsible (see
--          docs/connection-and-logging.md), not an instruction to
--          terminate them: an idle-in-transaction session may be a
--          batch job between statements, and terminating the wrong
--          session rolls back its work.
--
--          The logging settings in section 9 are the settings in
--          effect for the current session, so a setting changed with
--          ALTER DATABASE or ALTER ROLE for the connected database or
--          role shows here, while a postgresql.conf change that has
--          not been reloaded does not. The source column in
--          pg_settings (not shown) tells where each value came from.
--
--          Connection counts include this script's own connection.
--          The backend_type breakdown in section 4 separates client
--          backends from autovacuum workers, the WAL writer, and
--          other background processes, so a high total is not
--          mistaken for a client connection problem.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04, against a local lab database
--          with manufactured idle, idle-in-transaction, and active
--          sessions.

\pset border 2
\pset null '(null)'

-- Configurable thresholds. A default applies only when the variable was
-- not passed on the command line (psql -v), so -v always wins.
\if :{?warn_conn_pct}
\else
\set warn_conn_pct 80
\endif
\if :{?warn_idle_in_txn_min}
\else
\set warn_idle_in_txn_min 10
\endif
\if :{?warn_idle_min}
\else
\set warn_idle_min 60
\endif
\if :{?warn_active_min}
\else
\set warn_active_min 5
\endif

\echo ''
\echo '=== 1. Connection utilization vs max_connections ==='
SELECT (SELECT count(*) FROM pg_stat_activity) AS total_backends,
       (SELECT setting::int FROM pg_settings
        WHERE name = 'max_connections') AS max_connections,
       (SELECT setting::int FROM pg_settings
        WHERE name = 'superuser_reserved_connections')
         AS superuser_reserved_connections,
       round(100.0 * (SELECT count(*) FROM pg_stat_activity)
             / (SELECT setting::int FROM pg_settings
                WHERE name = 'max_connections'), 1)
         AS utilization_pct,
       CASE WHEN 100.0 * (SELECT count(*) FROM pg_stat_activity)
                 / (SELECT setting::int FROM pg_settings
                    WHERE name = 'max_connections') >= :warn_conn_pct
            THEN 'WARNING: connection utilization over threshold'
            ELSE 'OK' END AS status;

\echo ''
\echo '=== 2. Connections by database and state ==='
SELECT datname,
       state,
       count(*) AS connections,
       min(clock_timestamp() - state_change) AS newest_state_age,
       max(clock_timestamp() - state_change) AS oldest_state_age
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY datname, state
ORDER BY connections DESC, datname, state;

\echo ''
\echo '=== 3. Connections by user and application ==='
SELECT usename,
       coalesce(application_name, '(not set)') AS application_name,
       count(*) AS connections
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY usename, application_name
ORDER BY connections DESC, usename, application_name;

\echo ''
\echo '=== 4. Backends by type ==='
SELECT backend_type,
       count(*) AS backends
FROM pg_stat_activity
GROUP BY backend_type
ORDER BY backends DESC, backend_type;

\echo ''
\echo '=== 5. Idle in transaction and long idle sessions ==='
SELECT pid,
       usename,
       datname,
       state,
       clock_timestamp() - state_change AS state_age,
       wait_event_type,
       wait_event,
       left(query, 80) AS query_snippet,
       CASE WHEN state = 'idle in transaction'
                 AND clock_timestamp() - state_change
                     >= (:warn_idle_in_txn_min || ' minutes')::interval
            THEN 'WARNING: idle in transaction over threshold'
            WHEN state = 'idle'
                 AND clock_timestamp() - state_change
                     >= (:warn_idle_min || ' minutes')::interval
            THEN 'idle over threshold'
            ELSE 'OK' END AS status
FROM pg_stat_activity
WHERE state IN ('idle in transaction', 'idle')
ORDER BY state_age DESC;

\echo ''
\echo '=== 6. Long-running active queries ==='
SELECT pid,
       usename,
       datname,
       clock_timestamp() - query_start AS running_for,
       wait_event_type,
       wait_event,
       left(query, 80) AS query_snippet
FROM pg_stat_activity
WHERE state = 'active'
  AND clock_timestamp() - query_start
      >= (:warn_active_min || ' minutes')::interval
ORDER BY running_for DESC;

\echo ''
\echo '=== 7. Per-database connection limits ==='
SELECT d.datname,
       d.datconnlimit AS connection_limit,
       count(a.pid) AS current_connections
FROM pg_database d
LEFT JOIN pg_stat_activity a ON a.datid = d.oid
GROUP BY d.datname, d.datconnlimit
ORDER BY d.datname;

\echo ''
\echo '=== 8. Connection settings ==='
SELECT name,
       setting,
       unit,
       context,
       short_desc
FROM pg_settings
WHERE name IN ('max_connections',
               'superuser_reserved_connections',
               'reserved_connections',
               'idle_in_transaction_session_timeout',
               'statement_timeout',
               'lock_timeout',
               'idle_session_timeout')
ORDER BY name;

\echo ''
\echo '=== 9. Logging settings ==='
SELECT name,
       setting,
       unit,
       context,
       short_desc
FROM pg_settings
WHERE name IN ('logging_collector',
               'log_destination',
               'log_directory',
               'log_filename',
               'log_rotation_age',
               'log_rotation_size',
               'log_min_duration_statement',
               'log_min_error_statement',
               'log_connections',
               'log_disconnections',
               'log_line_prefix',
               'log_checkpoints',
               'log_lock_waits',
               'log_autovacuum_min_duration',
               'log_temp_files')
ORDER BY name;

\echo ''
\echo 'Connection and logging check complete.'
\echo 'Note: an idle-in-transaction session holds locks and blocks'
\echo 'VACUUM. Find out what it is waiting on before terminating it.'
