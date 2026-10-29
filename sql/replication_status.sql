-- replication_status.sql
--
-- Purpose: Streaming replication health check for a PostgreSQL instance.
--          Works on either side of the pair: on a primary it reports every
--          connected standby with send, write, flush, and replay lag; on a
--          replica it reports the WAL receiver connection and how far
--          replay sits behind received WAL. Replication slots and their
--          retained WAL are reported as well. Read-only; issues no writes.
--
-- Usage:   psql -h <host> -p 5432 -U <user> -d postgres \
--                 -v max_replay_lag_mb=16 \
--                 -f sql/replication_status.sql
--
--          The -v variable is optional. The default is set below.
--          A standby whose replay lag exceeds the threshold is flagged
--          WARNING; everything else reports OK. A lag flag is a prompt to
--          investigate (see docs/replication-setup.md), not a verdict on
--          its own: a standby under heavy write load can lag briefly
--          and catch up without any intervention.
--
-- Tested:  PostgreSQL 16 on Ubuntu 24.04, against a local primary and
--          replica pair built with pg_basebackup, including a paused
--          replay test that pushed lag past the threshold.

\pset border 2
\pset null '(null)'

-- Configurable threshold. The default applies only when the variable was
-- not passed on the command line (psql -v), so -v always wins.
\if :{?max_replay_lag_mb}
\else
\set max_replay_lag_mb 16
\endif

\echo ''
\echo '=== 1. Role ==='
SELECT pg_is_in_recovery() AS in_recovery,
       CASE WHEN pg_is_in_recovery()
            THEN 'replica (in recovery)'
            ELSE 'primary' END AS role,
       CASE WHEN pg_is_in_recovery()
            THEN pg_last_wal_replay_lsn()
            ELSE pg_current_wal_lsn() END AS wal_position;

\echo ''
\echo '=== 2a. Standbys connected to this primary (empty on a replica, or when none) ==='
SELECT application_name AS standby,
       client_addr,
       usename,
       state,
       sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)::bigint) AS send_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), write_lsn)::bigint) AS write_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), flush_lsn)::bigint) AS flush_lag,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint) AS replay_lag,
       CASE WHEN pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
                 > (:max_replay_lag_mb * 1048576)
            THEN 'WARNING: replay lag over threshold'
            ELSE 'OK' END AS status
FROM pg_stat_replication
ORDER BY application_name;

\echo ''
\echo '=== 2b. Primary standby verdict ==='
SELECT CASE WHEN pg_is_in_recovery()
            THEN 'n/a - this instance is a replica'
            WHEN NOT EXISTS (SELECT 1 FROM pg_stat_replication)
            THEN 'No standbys connected'
            ELSE (SELECT count(*)::text FROM pg_stat_replication)
                 || ' standby(ies) connected' END AS primary_standby_status;

\echo ''
\echo '=== 3a. WAL receiver (replica side; empty on a primary, or when not connected) ==='
SELECT status,
       slot_name,
       sender_host,
       sender_port,
       receive_start_lsn,
       pg_size_pretty(
         pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                         pg_last_wal_replay_lsn())::bigint) AS replay_lag,
       last_msg_receipt_time,
       now() - last_msg_receipt_time AS since_last_message
FROM pg_stat_wal_receiver;

\echo ''
\echo '=== 3b. Replica receiver verdict ==='
SELECT CASE WHEN NOT pg_is_in_recovery()
            THEN 'n/a - this instance is a primary'
            WHEN NOT EXISTS (SELECT 1 FROM pg_stat_wal_receiver)
            THEN 'WARNING: in recovery but no WAL receiver connected'
            ELSE 'WAL receiver connected' END AS replica_receiver_status;

\echo ''
\echo '=== 4. Replication slots (retained WAL matters on a primary) ==='
SELECT slot_name,
       slot_type,
       database,
       active,
       restart_lsn,
       CASE WHEN NOT pg_is_in_recovery() AND restart_lsn IS NOT NULL
            THEN pg_size_pretty(
                   pg_wal_lsn_diff(pg_current_wal_lsn(),
                                   restart_lsn)::bigint)
            ELSE 'n/a' END AS retained_wal_estimate
FROM pg_replication_slots
ORDER BY slot_name;

\echo ''
\echo 'Replication status check complete.'
