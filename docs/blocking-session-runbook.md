# Blocking-session runbook (PostgreSQL)

For the on-call DBA who gets paged with "the application is hanging" and needs
to find out whether the database is the reason.

## 1. Confirm it is a lock problem

Run `sql/blocking_sessions.sql`. A row in the first section means a session is
actively waiting on a lock held by another session. The second section shows the
exact lock type and object the waiter wants.

If the first section is empty, the hang is probably not lock contention. Check
long-running transactions in `sql/db_health_check.sql` (section 4) and look at
CPU, I/O, and connection counts before going further.

## 2. Read the chain

- `blocked_pid` is waiting; `blocking_pid` holds the lock.
- `wait_event_type` / `wait_event` say what kind of wait it is. `Lock` with
  `wait_event = transactionid` usually means an open transaction is holding row
  locks; `relation` means a table-level lock (often from DDL or `LOCK TABLE`).
- `blocked_secs` tells you how long the waiter has been stuck. Seconds are
  annoying; minutes are a page.
- Follow the chain: the blocker may itself be blocked by a third session. The
  session at the head of the chain, usually `idle in transaction`, is the one
  that matters.

## 3. Decide what to do

Common causes, in rough order of likelihood:

1. An application session opened a transaction, updated rows, and never
   committed. The fix is in the application, not the database.
2. A migration or DDL statement is holding an `AccessExclusiveLock` while
   other sessions queue behind it.
3. A long-running report or batch job is holding locks far longer than
   expected.
4. Autovacuum or another maintenance process is briefly blocking DDL. This
   usually clears on its own.

## 4. Safe reactions

- Prefer `SELECT pg_cancel_backend(pid)` first. It cancels the running query
  but leaves the session and its transaction handling to the application.
- Use `SELECT pg_terminate_backend(pid)` only when cancel does not work or the
  session is `idle in transaction` and will never commit. Termination rolls the
  session's open transaction back, which can take time on a large transaction.
- Never terminate `autovacuum worker`, `checkpointer`, `walwriter`, or `wal
  receiver` processes. They are background processes, not user sessions, and
  killing them does not fix a lock problem.
- Do not restart PostgreSQL to clear a lock. A restart is slower than a
  targeted terminate and interrupts every session, not just the stuck one.

## 5. Verify

Re-run `sql/blocking_sessions.sql`. The chain should be gone. Then check that
the application recovered: connection counts back to normal in
`sql/db_health_check.sql`, and the blocked queries completing in the
application logs.

## 6. Follow up

If the blocker was an uncommitted application transaction, that is an
application bug: connections must commit or roll back promptly, or use
statement timeouts. Consider `idle_in_transaction_session_timeout` on
application roles so the database defends itself next time. If the blocker was
a migration, schedule DDL in a maintenance window with `lock_timeout` set.
