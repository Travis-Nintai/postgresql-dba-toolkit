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
├── sql/    -- psql diagnostic scripts (health check, blocking sessions, replication status, vacuum and bloat, connection and logging) and the query tuning lab setup
├── bash/   -- runner and backup scripts with logging and exit codes
├── docs/   -- script conventions, runbooks, the backup and recovery lab, replication setup, the vacuum and bloat guide, the connection and logging guide, and the EXPLAIN ANALYZE tuning guide
└── logs/   -- timestamped output from each run (gitignored)
```

## Scripts

| Script | What it does |
|---|---|
| `sql/db_health_check.sql` | Instance overview: version and uptime, connection utilization vs `max_connections`, database sizes, long-running transactions, replication state, autovacuum activity |
| `sql/blocking_sessions.sql` | Current blocking chains: blocked and blocking sessions, wait events, lock detail |
| `bash/run_sql_check.sh` | Runs any SQL script with a connectivity probe, timestamped logging, and stable exit codes |
| `bash/backup_database.sh` | Verified logical backup of one database: `pg_dump` with connectivity probe, then reads the archive back with `pg_restore --list` before calling it done |
| `sql/replication_status.sql` | Streaming replication health: connected standbys with send, write, flush, and replay lag on a primary; WAL receiver state on a replica; replication slots and retained WAL, with a configurable lag threshold |
| `sql/vacuum_bloat_check.sql` | Vacuum health and bloat review: autovacuum settings, vacuums running now, tables by dead tuple load with a configurable flag threshold, never-vacuumed tables, transaction ID wraparound risk, transactions holding back the vacuum horizon, and large unused indexes |
| `sql/connection_and_logging_check.sql` | Connection management and logging review: utilization against `max_connections`, connections by database, user, application, state, and backend type, idle-in-transaction and long idle sessions, long-running active queries, per-database connection limits, and the connection and logging settings in effect |
| `sql/query_tuning_lab_setup.sql` | Builds the lab data for the query tuning guide: two fictional tables with only primary keys indexed, so the guide's queries run slowly first and fast after the indexes it adds |

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

Backup of one database, with the archive read back and verified before the
script reports success:

```
bash/backup_database.sh -d appdb -o ./backups
```

`docs/backup-recovery-lab.md` walks through the full backup picture:
logical backups and selective restore, `pg_basebackup`, WAL archiving, and
the point-in-time recovery sequence, with a restore-and-compare
verification at the end of each part.

Replication status on either side of a pair, flagging replay lag over 16 MB:

```
psql -h db.example.local -U dba -d postgres -v max_replay_lag_mb=16 -f sql/replication_status.sql
```

`docs/replication-setup.md` covers building a standby with
`pg_basebackup`, monitoring it with this script, synchronous replication
tradeoffs, promotion steps, and troubleshooting for lag and disconnected
standbys.

Vacuum and bloat review, flagging tables over 20 percent dead tuples
with at least 1,000 dead rows:

```
psql -h db.example.local -U dba -d appdb -f sql/vacuum_bloat_check.sql
```

`docs/vacuum-bloat-guide.md` explains why dead tuples accumulate, how
to read each section of the output, when a plain VACUUM is enough, and
when shrinking a table or rebuilding an index is a planned maintenance
action instead.

Connection and logging review, flagging idle-in-transaction sessions
older than 10 minutes and idle sessions older than 60 minutes:

```
psql -h db.example.local -U dba -d appdb -f sql/connection_and_logging_check.sql
```

`docs/connection-and-logging.md` explains how to read each section,
what the connection and logging settings mean, when a pooler is the
answer instead of a larger `max_connections`, and what to check when a
logging change seems to have no effect.

Build the query tuning lab data (100,000 orders, 300,000 line items,
fictional and reproducible):

```
psql -h db.example.local -U dba -d labdb -f sql/query_tuning_lab_setup.sql
```

`docs/explain-analyze-tuning.md` walks through two slow queries with
their real before and after plans: a recent-orders query fixed by one
composite index, and a customer line-item join fixed by indexing the
foreign key, plus the trap of a function on an indexed column that
makes the planner ignore the index.

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

The backup workflow was tested end to end on the same PostgreSQL 16
instance: a 10,000 row test table was dumped with `backup_database.sh`
(exit 0, archive listing verified), restored into a second database, and
confirmed identical by row count and value aggregates. A `pg_basebackup`
base backup with WAL streaming also completed. The point-in-time recovery
replay is documented as a walkthrough in the lab and was not executed end
to end; the lab document says so plainly.

The replication check was tested end to end on the same PostgreSQL 16
instance with a local standby built by `pg_basebackup`: the standalone
path reported no standbys correctly, the streaming pair showed zero lag
on both sides with a 200 row table matching exactly, and a paused-replay
test pushed replay lag to 31 kB and tripped the WARNING flag at a zero
threshold before both sides matched again at 400 rows after replay
resumed.

The vacuum and bloat check was tested on the same PostgreSQL 16
instance with a lab table carrying 2,000 dead tuples against 3,000
live rows (40 percent dead): it flagged the table VACUUM RECOMMENDED
at the default thresholds, reported OK with a 90 percent threshold
override, listed the never-scanned index with a zero size threshold
override, showed a held transaction in the vacuum horizon section,
and reported zero dead tuples and a smaller table (472 kB to 384 kB)
after a manual VACUUM.

The connection and logging check was tested on the same PostgreSQL 16
instance with manufactured sessions: one idle, one idle in transaction,
and one active session running `pg_sleep(240)`. With all thresholds set
to zero it reported 9 backends against `max_connections` 100 (9.0
percent, WARNING at a zero threshold), flagged the idle-in-transaction
session WARNING and the idle session as idle over threshold, and listed
the sleeping session with wait event type Timeout and wait event
PgSleep. The same sessions at the default thresholds, 37 seconds old,
reported OK. The logging section was verified to reflect a real change:
after `ALTER DATABASE labdb SET log_min_duration_statement = 500` it
showed 500 for that database while the others kept the -1 default.

The query tuning lab was tested on the same PostgreSQL 16 instance
with 100,000 orders and 300,000 line items: the recent shipped orders
query fell from 8.6 ms to 0.11 ms after one composite index (878
buffer hits to 23, sequential scan and sort replaced by an index
scan), and the customer line-item join fell from 42.6 ms to 6.8 ms
after indexing the foreign key, with a follow-up customer index
taking it to 0.27 ms. A query filtering on `lower(status)` ignored
the index and ran a sequential scan at 12.4 ms, which the guide
documents as a trap rather than a tuning win. Each query was run
twice with matching results.

## Safety notes

- Everything in `sql/` is read-only except `query_tuning_lab_setup.sql`,
  which builds lab tables and loads fictional data into the database
  you point it at, and drops those tables first if they exist. The
  diagnostic scripts query statistics and catalog views; they change
  nothing. The backup script writes backup files to a directory you
  choose, and nothing else.
- Terminating sessions is a deliberate manual action covered by the runbook,
  never something these scripts do on their own.
- Never commit credentials, hostnames, or environment-specific details
  alongside these scripts.

## What this demonstrates

PostgreSQL-native operational diagnostics: `pg_stat_activity` and `pg_locks`
for session and lock analysis, `pg_stat_replication` and
`pg_stat_wal_receiver` for standby lag on both sides of a pair, replication
slot and retained WAL awareness, autovacuum awareness, connection
utilization and idle-in-transaction diagnosis with the logging settings
that explain them, `EXPLAIN ANALYZE`
plan reading with before and after evidence for index tuning, and the judgment to
cancel before terminating. The same disciplines as the Oracle toolkit,
implemented the PostgreSQL way.

## Background

Independent portfolio project. Scripts were developed and tested in a local
lab environment with fictional data, not taken from any production system or
employer.
