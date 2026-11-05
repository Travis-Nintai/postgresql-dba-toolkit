-- vacuum_bloat_check.sql
--
-- Purpose: Vacuum health and bloat review for a PostgreSQL instance.
--          Reports autovacuum settings, vacuums running right now,
--          tables carrying enough dead tuples to need a vacuum, tables
--          that have never been vacuumed, transaction ID wraparound
--          risk, long-running transactions holding back the vacuum
--          horizon, and large indexes with no scans. Read-only; issues
--          no writes and never vacuums anything itself.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d <database> \
--                 -v warn_dead_pct=20 -v min_dead_tup=1000 \
--                 -v warn_xid_age=100000000 \
--                 -v min_unused_index_mb=10 \
--                 -f sql/vacuum_bloat_check.sql
--
--          All -v variables are optional. The defaults are set below.
--          A table is flagged VACUUM RECOMMENDED when its dead tuple
--          share reaches warn_dead_pct and its dead tuple count reaches
--          min_dead_tup. The count floor keeps tiny tables with a few
--          dead rows out of the flagged list. A flag is a prompt to
--          check autovacuum for that table (see
--          docs/vacuum-bloat-guide.md), not an order to run VACUUM
--          FULL: ordinary VACUUM reclaims dead space for reuse, while
--          VACUUM FULL rewrites the table and takes an access exclusive
--          lock, so it is a planned maintenance action, not a reflex.
--
--          This script uses the dead tuple ratio as its bloat signal
--          because it is cheap and always available. It is an estimate
--          of reclaimable space, not an exact measurement: for exact
--          per-table bloat figures, pgstattuple (postgresql-contrib)
--          measures the live table directly. Dead tuple counts also
--          move as autovacuum works, so a flagged table may clear
--          itself on the next run.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04, against a local lab database
--          with a table carrying a manufactured dead tuple load.

\pset border 2
\pset null '(null)'

-- Configurable thresholds. A default applies only when the variable was
-- not passed on the command line (psql -v), so -v always wins.
\if :{?warn_dead_pct}
\else
\set warn_dead_pct 20
\endif
\if :{?min_dead_tup}
\else
\set min_dead_tup 1000
\endif
\if :{?warn_xid_age}
\else
\set warn_xid_age 100000000
\endif
\if :{?min_unused_index_mb}
\else
\set min_unused_index_mb 10
\endif

\echo ''
\echo '=== 1. Autovacuum settings (current database) ==='
SELECT name,
       setting,
       unit,
       context
FROM pg_settings
WHERE name IN ('autovacuum',
               'track_counts',
               'autovacuum_max_workers',
               'autovacuum_naptime',
               'autovacuum_vacuum_threshold',
               'autovacuum_vacuum_scale_factor',
               'autovacuum_vacuum_insert_threshold',
               'autovacuum_vacuum_insert_scale_factor',
               'autovacuum_analyze_threshold',
               'autovacuum_analyze_scale_factor',
               'autovacuum_freeze_max_age',
               'log_autovacuum_min_duration')
ORDER BY name;

\echo ''
\echo '=== 2. Vacuums running now ==='
SELECT p.pid,
       p.datname,
       p.phase,
       c.relname AS table_name,
       p.heap_blks_total,
       p.heap_blks_scanned,
       p.heap_blks_vacuumed,
       p.num_dead_tuples,
       a.state,
       a.query_start
FROM pg_stat_progress_vacuum p
LEFT JOIN pg_class c ON c.oid = p.relid
LEFT JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY p.pid;

\echo ''
\echo '=== 3. Tables by dead tuple load (flagged at the thresholds above) ==='
SELECT schemaname,
       relname AS table_name,
       n_live_tup AS live_tuples,
       n_dead_tup AS dead_tuples,
       round(100.0 * n_dead_tup
             / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       last_vacuum,
       last_autovacuum,
       CASE WHEN n_dead_tup >= :min_dead_tup
                 AND 100.0 * n_dead_tup
                     / NULLIF(n_live_tup + n_dead_tup, 0)
                     >= :warn_dead_pct
            THEN 'VACUUM RECOMMENDED'
            ELSE 'OK' END AS status
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;

\echo ''
\echo '=== 4. Tables never vacuumed, and analyze staleness ==='
SELECT schemaname,
       relname AS table_name,
       n_live_tup AS live_tuples,
       n_dead_tup AS dead_tuples,
       n_mod_since_analyze AS changed_since_analyze,
       last_vacuum,
       last_autovacuum,
       last_analyze,
       last_autoanalyze,
       CASE WHEN last_vacuum IS NULL AND last_autovacuum IS NULL
            THEN 'NEVER VACUUMED'
            ELSE 'vacuumed before' END AS vacuum_history
FROM pg_stat_user_tables
WHERE (last_vacuum IS NULL AND last_autovacuum IS NULL)
   OR (n_mod_since_analyze > 0 AND last_autoanalyze IS NULL
       AND last_analyze IS NULL)
ORDER BY n_dead_tup DESC;

\echo ''
\echo '=== 5a. Transaction ID wraparound risk by database ==='
SELECT datname,
       age(datfrozenxid) AS xid_age,
       CASE WHEN age(datfrozenxid) >= :warn_xid_age
            THEN 'WARNING: frozen XID age over threshold'
            ELSE 'OK' END AS status
FROM pg_database
ORDER BY xid_age DESC;

\echo ''
\echo '=== 5b. Tables closest to the wraparound limit (top 10 by frozen XID age) ==='
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       age(c.relfrozenxid) AS xid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
ORDER BY xid_age DESC
LIMIT 10;

\echo ''
\echo '=== 6. Long-running transactions holding back the vacuum horizon ==='
SELECT pid,
       usename,
       state,
       age(backend_xmin) AS xmin_age,
       now() - xact_start AS transaction_age,
       wait_event_type,
       wait_event,
       left(query, 80) AS query_snippet
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
  AND state <> 'idle'
ORDER BY xmin_age DESC;

\echo ''
\echo '=== 7. Large indexes with no scans (review candidates, not drop orders) ==='
SELECT schemaname,
       relname AS table_name,
       indexrelname AS index_name,
       idx_scan AS scans,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND pg_relation_size(indexrelid) >= (:min_unused_index_mb * 1048576)
ORDER BY pg_relation_size(indexrelid) DESC;

\echo ''
\echo 'Vacuum and bloat check complete.'
\echo 'Note: an unused index may still be needed (unique constraints and'
\echo 'foreign key support both rely on indexes). Confirm before dropping.'
