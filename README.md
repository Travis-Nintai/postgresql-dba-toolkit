# PostgreSQL DBA Toolkit

Operational scripts for PostgreSQL database administration: instance health
checks, blocking-session diagnosis, and the runbooks that go with them. Built
the way on-call work actually happens: check what is wrong, find the sessions
responsible, fix it safely, verify the fix.

## Who it is for

DBAs who administer PostgreSQL and want a small set of dependable diagnostic
scripts with honest documentation. Every script here was executed against a real
PostgreSQL instance during development, not just reviewed.

## Layout

```
postgresql-dba-toolkit/
├── sql/    -- psql diagnostic scripts (health check, blocking sessions)
├── bash/   -- runner that executes a SQL script with logging and exit codes
├── docs/   -- script conventions and the blocking-session runbook
└── logs/   -- timestamped output from each run (gitignored)
```

## Scripts

| Script | What it does |
|---|---|
| `sql/db_health_check.sql` | Instance overview: version and uptime, connection utilization vs `max_connections`, database sizes, long-running transactions, replication state, autovacuum activity |
| `sql/blocking_sessions.sql` | Current blocking chains: blocked and blocking sessions, wait events, lock detail |
| `bash/run_sql_check.sh` | Runs any SQL script with a connectivity probe, timestamped logging, and stable exit codes |

Health check with defaults:

```
psql -h db.example.local -U dba -d postgres -f sql/db_health_check.sql
```

Tune the thresholds without editing the script:

```
psql -h db.example.local -U dba -d postgres -v warn_conn_pct=90 -v long_txn_min=10 -f sql/db_health_check.sql
```

Blocking sessions blocked longer than 60 seconds, through the runner:

```
bash/run_sql_check.sh -f sql/blocking_sessions.sql -h db.example.local -U dba -d appdb -v min_wait_secs=60
```

When a blocking chain shows up, work it with `docs/blocking-session-runbook.md`
before terminating anything.

## Assumptions

- PostgreSQL 10 or later. `pg_blocking_pids()` and the statistics views used
  here exist in every supported version, and the conditional `\set` defaults
  need psql 10 or later.
- Run as a user that can read `pg_stat_activity`, `pg_locks`, and
  `pg_stat_replication`. A superuser works; a dedicated monitoring role with
  `pg_monitor` granted is the better production answer.
- Connection details come from libpq environment variables (`PGHOST`,
  `PGPORT`, `PGUSER`, `PGDATABASE`) or command-line flags. No credentials in
  scripts, logs, or the repository.
- Hostnames and values in examples are fictional.

## Testing

The SQL scripts were executed against PostgreSQL 16 on Ubuntu 24.04, including
a manufactured blocking scenario (one session holding a row lock while a second
session waited on it) to verify `blocking_sessions.sql` reports the chain
correctly. The bash runner was tested for its success path, a bad hostname
(exit 2), and a failing SQL script (exit 3).

## Safety notes

- Everything here is read-only. The scripts query statistics and catalog views;
  they change nothing.
- Terminating sessions is a deliberate manual action covered by the runbook,
  never something these scripts do on their own.
- Never commit credentials, hostnames, or environment-specific details
  alongside these scripts.

## What this demonstrates

PostgreSQL-native operational diagnostics: `pg_stat_activity` and `pg_locks`
for session and lock analysis, `pg_stat_replication` for standby lag,
autovacuum awareness, and the judgment to cancel before terminating. The same
disciplines as the Oracle toolkit, implemented the PostgreSQL way.

## Background

Independent portfolio project. Scripts were developed and tested in a local
lab environment with fictional data, not taken from any production system or
employer.
