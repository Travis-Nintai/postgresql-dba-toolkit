-- blocking_sessions.sql
--
-- Purpose: Show current blocking chains: which sessions are blocked, which
--          sessions are blocking them, what each is waiting on, and how long
--          the blocked session has been waiting. Read-only.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d <database> \
--                 -v min_wait_secs=30 -f sql/blocking_sessions.sql
--
--          min_wait_secs filters to sessions blocked longer than N seconds.
--          Default 0 shows every currently blocked session.
--
-- Notes:   Uses pg_blocking_pids() (PostgreSQL 9.6+) and psql 10+ meta-commands.
--          A session can appear more than once when several blockers hold
--          locks on it.
--          Terminating a session is a separate, deliberate action; see
--          docs/blocking-session-runbook.md before killing anything.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04.

\pset border 2
\pset null '(null)'

-- Configurable threshold. The default applies only when the variable was
-- not passed on the command line (psql -v), so -v always wins.
\if :{?min_wait_secs}
\else
\set min_wait_secs 0
\endif

\echo ''
\echo '=== Currently blocked sessions ==='
SELECT blocked.pid                    AS blocked_pid,
       blocked.usename                AS blocked_user,
       blocked.application_name       AS blocked_app,
       blocking.pid                   AS blocking_pid,
       blocking.usename               AS blocking_user,
       blocking.application_name      AS blocking_app,
       blocked.wait_event_type        AS wait_type,
       blocked.wait_event             AS wait_event,
       extract(epoch FROM (now() - blocked.query_start))::int AS blocked_secs,
       left(blocked.query, 70)        AS blocked_query,
       left(blocking.query, 70)       AS blocking_query
FROM pg_stat_activity AS blocked
JOIN pg_stat_activity AS blocking
  ON blocking.pid = ANY (pg_blocking_pids(blocked.pid))
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
  AND extract(epoch FROM (now() - blocked.query_start)) >= :min_wait_secs
ORDER BY blocked_secs DESC;

\echo ''
\echo '=== Lock detail for blocked sessions ==='
SELECT l.pid                          AS blocked_pid,
       locktype,
       CASE WHEN l.database <> 0 THEN l.database::regclass::text
            ELSE '(shared object)' END AS locked_object,
       CASE WHEN l.relation <> 0 THEN l.relation::regclass::text
            ELSE NULL END              AS locked_relation,
       mode                           AS lock_mode_requested,
       granted
FROM pg_locks l
WHERE l.pid IN (SELECT pid FROM pg_stat_activity
                WHERE cardinality(pg_blocking_pids(pid)) > 0)
  AND NOT l.granted
ORDER BY l.pid;

\echo ''
\echo 'Blocking-session check complete.'
