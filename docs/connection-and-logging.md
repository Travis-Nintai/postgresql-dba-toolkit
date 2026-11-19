# Connection management and logging

How to read `sql/connection_and_logging_check.sql`, what the settings mean,
and what to do when the numbers look wrong. The script is read-only: it
reports state and never terminates a session or changes a setting.

## Why this check exists

Most PostgreSQL outages that look like database problems are connection
problems. An application opens a connection per request and never closes
it, a batch job holds a transaction open for hours, or a deploy doubles
the connection count overnight, and the instance hits `max_connections`
while the database itself is healthy. The second half of the problem is
that when something does go wrong, the logs do not say enough: slow query
logging was never turned on, connections were never logged, or the log
line prefix does not include the fields needed to match a log line to a
session. This check covers both halves in one run, so the state of the
connections and the state of the logging that would explain them are
visible together.

## What each section means

### 1. Connection utilization vs max_connections

Total backends against `max_connections`, as a percentage, with a status
flag at the `warn_conn_pct` threshold (default 80). Total backends counts
every backend in `pg_stat_activity`, including background processes, so
compare it with section 4 before concluding the clients are the problem.
On a quiet instance the background processes alone are five or six
backends: autovacuum launcher, background writer, checkpointer, WAL
writer, and the logical replication launcher.

`superuser_reserved_connections` (default 3) is the number of slots held
back for superusers. When utilization reaches `max_connections` minus
that reserve, ordinary users get "remaining connection slots are reserved
for non-replication superuser connections" while a superuser can still
connect to investigate. That reserve is the reason the first response to
a connection exhaustion is to connect as a superuser and look, not to
restart the instance.

### 2. Connections by database and state

One row per database and state, with the newest and oldest age in that
state. The states that matter most:

- `active`: running a query right now. A large active count with high
  CPU is a workload problem, not a connection problem.
- `idle`: connected, between statements, holding no transaction. Idle
  connections are normal for pooled applications and mostly harmless,
  but thousands of them still cost memory and make every new connection
  slower to set up.
- `idle in transaction`: connected, inside an open transaction, between
  statements. This is the dangerous one. It holds locks, blocks VACUUM
  from reclaiming dead tuples, and holds back the transaction ID
  horizon, which is how a quiet session eventually causes wraparound
  pressure. Section 5 names the sessions.
- `idle in transaction (aborted)`: the transaction hit an error and the
  session is waiting for a ROLLBACK. Same costs as idle in transaction,
  and usually a sign the application does not handle errors.
- `disabled`: a session whose backend is being terminated.

### 3. Connections by user and application

Who is connected and from what, by `application_name`. This is the
section that turns a total into an owner. If one application accounts
for most of the connections, the fix belongs in that application's
pooling, not in `max_connections`. The value comes from the client's
connection string or driver setting, so applications that never set it
show as "(not set)" and are grouped together; getting teams to set a
real application name is one of the cheapest monitoring improvements
available.

### 4. Backends by type

Separates client backends from background processes. Read it with
section 1: if total backends are high but client backends are not, the
instance is not short of client connection slots.

### 5. Idle in transaction and long idle sessions

Every idle and idle-in-transaction session, oldest first, with the query
it ran last. The status flag uses two thresholds: idle-in-transaction
sessions older than `warn_idle_in_txn_min` minutes (default 10) are
WARNING, idle sessions older than `warn_idle_min` minutes (default 60)
are flagged as idle over threshold. Both flags are prompts to
investigate, not orders to terminate. Before terminating an
idle-in-transaction session, find out what it is: the query snippet,
the application name, and whether it holds locks (`blocking_sessions.sql`
in this repo shows the lock side). Terminating rolls back the open
transaction, so a session that turns out to be a batch job between
statements loses its work.

A session that sits idle in transaction for hours usually means one of
three things: the application opened a transaction and forgot to commit
or roll back, a framework holds a connection with an open transaction
across user think time, or an interactive session was left open. The
first two are fixed in the application. The third is fixed by
`idle_in_transaction_session_timeout`, which terminates sessions that
stay idle in a transaction past the limit. Setting it is safe in the
sense that it only fires on sessions doing nothing, but it does roll
back their transaction, so set it per database or role for application
accounts rather than globally when interactive users share the
instance.

### 6. Long-running active queries

Active sessions older than `warn_active_min` minutes (default 5), with
the wait event. A session with no wait event is on CPU. `ClientRead`
means it is waiting on the client, which for an active session usually
means a large result set still being sent. `IO` wait events point at
storage. Cross-reference with `EXPLAIN ANALYZE` before concluding a
query is slow: a query that has run for an hour may be a legitimate
batch job, and the wait event and the query text say which.

### 7. Per-database connection limits

Every database, its `datconnlimit` (-1 means no limit), and its current
connection count. A per-database limit is the usual answer when one
database's application keeps taking the whole instance down with it:
set the limit with `ALTER DATABASE ... CONNECTION LIMIT n` and that
database fails on its own instead of starving the others.

### 8. Connection settings

The settings that govern connections, in effect for the current
session:

- `max_connections`: the hard ceiling. Raising it is rarely the right
  fix on its own: each connection costs memory and backend overhead,
  and a value far above what the workload needs hides the pooling
  problem until it is larger.
- `superuser_reserved_connections` and `reserved_connections`: slots
  held back for superusers and for roles with
  `pg_use_reserved_connections`. The reserved slots are what let a DBA
  connect during an exhaustion.
- `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout`,
  `idle_session_timeout`: all zero means disabled, which is the
  PostgreSQL default. A `statement_timeout` set at the database or role
  level is the usual protection against a runaway query, and it is set
  where the workload lives, not globally, so interactive sessions are
  not cut off mid-investigation. `lock_timeout` bounds how long a
  session waits for a lock, which keeps a blocked DDL statement from
  queueing behind everything else indefinitely.

### 9. Logging settings

The logging settings in effect for the current session, with the context
each one needs. Context matters: `postmaster` settings need a restart,
`sighup` settings need a reload, `superuser` and `user` settings can
change per session, and `superuser-backend` settings apply to new
sessions. A setting changed in `postgresql.conf` without a reload does
not show here, which is the first thing to check when a logging change
seems to have no effect.

The settings worth having an opinion about:

- `logging_collector` and `log_destination`: on Debian-packaged
  PostgreSQL the collector is off by default and logs go to stderr,
  which the service captures in the journal. Turning the collector on
  writes log files under `log_directory` instead, which is the better
  answer when logs need rotation and retention independent of the
  journal.
- `log_min_duration_statement`: -1 (the default) means slow query
  logging is off. Setting it to a value like 500 logs every statement
  slower than 500 ms with its duration, which is the cheapest slow
  query monitoring available. Setting it to 0 logs everything and is a
  debugging measure, not a steady state.
- `log_connections` and `log_disconnections`: off by default. Turning
  both on gives a connection audit trail with session durations, which
  is how connection leaks get proven rather than suspected. On a busy
  instance the volume is high, so this is often enabled for a bounded
  investigation rather than permanently.
- `log_line_prefix`: the default `%m [%p] %q%u@%d` gives timestamp,
  process ID, user, and database on every line. Without the process ID
  and database, a log line cannot be matched to a session in
  `pg_stat_activity`.
- `log_checkpoints`, `log_lock_waits`, `log_autovacuum_min_duration`,
  `log_temp_files`: checkpoint logging shows checkpoint frequency and
  write volume, lock-wait logging catches the waits that become
  blocking incidents, autovacuum logging at 10 minutes (the default
  600,000 ms) is the record of whether autovacuum keeps up, and
  `log_temp_files` set to a size like 1024 logs every sort or hash
  that spills to disk above 1 MB, which is a query tuning signal.

## Connection pooling

When the check shows more connections than the workload justifies, the
fix is usually a pooler rather than a larger `max_connections`. PgBouncer
in transaction pooling mode is the standard answer: application
connections share a small number of real server connections, and a
server connection is only held for the duration of a transaction. Two
things change when a pooler is in front of the database. First, the
connection counts in this script count the pooler's server connections,
not the application connections, so per-application attribution comes
from the pooler's own statistics instead. Second, session-level features
stop working across transactions: prepared statements, `SET` variables,
temporary tables, and advisory locks do not survive a transaction
boundary in transaction pooling mode. Applications that rely on them
need session pooling mode, or the feature needs to move out of the
session.

## Troubleshooting

| Symptom | Where to look | Likely cause |
|---|---|---|
| "remaining connection slots are reserved" | Section 1, then section 3 | Connection leak or missing pooler in one application; check the top application by count |
| Utilization high, mostly idle | Sections 2, 3, 5 | Pool per application is oversized, or connections are opened and never closed |
| One session idle in transaction for hours | Section 5, then `blocking_sessions.sql` | Uncommitted transaction, often a framework holding a connection across user think time |
| Checkpoints too frequent | Section 9, `log_checkpoints` | `max_wal_size` too small for the write rate; see the checkpoint log lines for write volume |
| Slow queries with no log evidence | Section 9, `log_min_duration_statement` | Slow query logging off (-1); set it per database and watch the logs |
| A logging change has no effect | Section 9, the context column | The setting needs a reload or restart, or was set at a level that does not apply to this session |
| One database starves the others | Section 7 | No per-database connection limit; set one with `ALTER DATABASE ... CONNECTION LIMIT` |

## Lab results

Tested on PostgreSQL 16.15, Ubuntu 24.04, against a local lab database.

A default run on a fresh instance showed 6 total backends against
`max_connections` 100 (6.0 percent, OK): one client backend running the
script and five background processes. Sections 5 and 6 were empty, and
the logging section showed the Debian defaults, including
`logging_collector` off, `log_min_duration_statement` -1, and
`log_connections` and `log_disconnections` off.

Three sessions were then manufactured to exercise the flags: one idle
session, one idle-in-transaction session (a transaction left open after
a SELECT), and one active session running `pg_sleep(240)`. A run with
all thresholds set to zero reported 9 backends (9.0 percent, WARNING at
a zero threshold), grouped the lab database as 2 active, 1 idle, and 1
idle in transaction, listed each session under its application name in
section 3, flagged the idle-in-transaction session WARNING and the idle
session as idle over threshold, and listed the `pg_sleep` session in
section 6 with wait event type Timeout and wait event PgSleep. The same
sessions at the default thresholds, 37 seconds old, reported OK in
section 5, which is the thresholds working as designed rather than the
sessions being missed.

The logging section was verified to reflect a real change: after
`ALTER DATABASE labdb SET log_min_duration_statement = 500`,
section 9 showed `log_min_duration_statement` as 500 on a new
connection to that database, while the other databases kept the -1
default. The lab database was dropped after testing.
