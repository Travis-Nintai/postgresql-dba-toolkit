# Vacuum and Bloat Guide

Why dead tuples matter, how to read `sql/vacuum_bloat_check.sql`, and what
to do about what it reports. This is a companion to the script, not a
replacement for it: run the script first, then use this guide to interpret
the flagged rows.

## Why vacuum exists

PostgreSQL uses multi-version concurrency control. An UPDATE does not
overwrite a row in place; it marks the old version dead and writes a new
one. A DELETE marks the row dead. Dead versions stay on disk until vacuum
removes them, because a concurrent transaction might still need to see
the old version. That is normal and by design. It becomes a problem only
when dead versions accumulate faster than they are cleaned up: tables
grow, scans read dead pages, index entries point at dead rows, and query
plans get slower for no change in live data.

Autovacuum handles this in the background. It wakes up on a schedule
(`autovacuum_naptime`, 60 seconds by default) and vacuums a table once
the number of dead tuples passes a threshold: a base count plus a
fraction of the table size (`autovacuum_vacuum_threshold` plus
`autovacuum_vacuum_scale_factor` times the live row estimate, 50 plus
20 percent by default). The same mechanism runs ANALYZE on a parallel
threshold so the planner keeps current statistics. On most systems the
defaults are fine and the right response to a flagged table is to check
why autovacuum is not keeping up, not to start vacuuming by hand.

## Reading the script output

The script has seven sections. Only sections 3, 5a, and 7 carry flags;
the rest is context for the investigation.

Section 1 lists the autovacuum settings in effect. Check these first
when a table is flagged: `autovacuum` off, `track_counts` off, or a
per-table `autovacuum_enabled = false` override (set with ALTER TABLE)
all explain a growing dead tuple count. Per-table storage parameters
are visible in `pg_class.reloptions` and override the global settings
for that table.

Section 2 shows vacuums running right now, with phase and blocks
scanned versus total. A flagged table with a vacuum already in progress
needs patience, not a second vacuum.

Section 3 is the main flag list: live tuples, dead tuples, dead
percentage, total size, and last vacuum dates. The defaults flag a table
at 20 percent dead tuples with at least 1,000 dead rows. The count floor
matters: a 50 row lookup table with 20 dead rows is 29 percent dead and
irrelevant, while a 10 million row table at 20 percent holds 2 million
dead rows worth chasing. Tune both thresholds with `-v` rather than
editing the script.

Section 4 lists tables that have never been vacuumed and tables with
changes since their last ANALYZE but no analyze on record. A new table
that has only ever been inserted into will appear here with zero dead
tuples; that is expected, not a problem. The row to act on is a table
with both a high dead count and no vacuum history, which usually means
autovacuum is disabled for it or blocked.

Section 5 covers transaction ID wraparound. PostgreSQL transaction IDs
are 32 bit and wrap after about 4 billion transactions; frozen rows
stop the counter from wrapping past live data. The script reports the
frozen XID age per database and the ten tables with the oldest frozen
XIDs. The default warning threshold is 100 million, halfway to the
200 million `autovacuum_freeze_max_age` at which autovacuum starts
issuing warnings of its own. A database approaching that age needs
aggressive vacuum attention before it reaches the point where
PostgreSQL stops accepting writes to protect itself. On a healthy
system these ages sit in the low millions at most.

Section 6 lists transactions holding back the vacuum horizon. Vacuum
cannot remove a dead version newer than the oldest still-running
transaction, because that transaction might still read it. A single
long-running or idle-in-transaction session can therefore stall cleanup
across the whole database, and the dead tuple count will climb even
though autovacuum is running. The fix is at the session level: find out
why the transaction is open, and end it or get its owner to commit. Do
not terminate sessions blindly; the blocking-session runbook
(`docs/blocking-session-runbook.md`) covers that judgment call.

Section 7 lists large indexes with zero scans. An unused index costs
write performance and vacuum work on every change to its table, so it
is worth reviewing, but it is a candidate list, not a drop list. Unique
indexes enforce constraints, and indexes on foreign key columns keep
referential checks and joins fast even when they rarely appear as the
top of a plan. Confirm an index is truly unneeded (check with the
application owner, and consider `pg_stat_statements` history) before
dropping it.

## What to do about a flagged table

Work in this order:

1. Confirm autovacuum is enabled globally and for the table. Check
   section 1 and the table's `reloptions`. A table with
   `autovacuum_enabled = false` is usually that way for a reason
   (bulk load windows, for example); re-enable it deliberately or
   schedule manual VACUUM around the load, and document the choice.
2. Check section 6 for a blocking horizon. If an old transaction is
   holding back cleanup, resolve the session first; vacuuming before
   that will do little, because the dead rows cannot be reclaimed yet.
3. Check section 2. If a vacuum is already running on the table, wait
   for it and re-run the script.
4. Run a plain `VACUUM` on the table. It reclaims dead space for reuse
   inside the table without locking out readers or writers, and it is
   safe to run during business hours. Re-run the script afterward and
   confirm the dead count dropped.
5. If the table stays large after VACUUM even though most rows are
   gone, the space is not returned to the operating system by design:
   VACUUM frees pages for reuse, it does not shrink the file. Shrinking
   needs `VACUUM FULL` (rewrites the table under an access exclusive
   lock) or `pg_repack` (an external extension that rebuilds with
   less locking). Both are planned maintenance actions with a window
   and a rollback plan, not reactions to a single flagged run.

## Bloat beyond dead tuples

Dead tuples are the most common bloat source and the one this script
measures, but they are not the only one. A table can also be bloated
by free space left after a large delete that VACUUM has already
processed (the file stays large until rewritten), and an index can be
bloated by page splits and dead entries that only a REINDEX addresses.
`REINDEX CONCURRENTLY` rebuilds an index without blocking writes and is
the usual answer for a bloated index; `REINDEX` without CONCURRENTLY
locks the table. For exact per-table bloat measurements, the
`pgstattuple` extension (in postgresql-contrib) inspects the table
directly and reports free space precisely, at the cost of scanning the
whole table. Use it when a sizing decision depends on the number, not
for routine monitoring.

## Autovacuum tuning notes

Tune thresholds per table, not globally, unless the whole instance
shows the same symptom. Tables with heavy UPDATE or DELETE traffic
want a lower scale factor (for example, 0.05) so vacuum triggers
earlier; mostly static tables can tolerate a higher one. Raising
`autovacuum_max_workers` helps when many tables queue at once, but
each worker adds I/O, so watch disk latency when changing it.
`log_autovacuum_min_duration` set to a value like 1000 (milliseconds)
logs any autovacuum run longer than a second, which is the cheapest
way to learn which tables autovacuum actually struggles with.
`autovacuum_freeze_max_age` should not be raised to silence
wraparound warnings; the warning is telling you vacuum is behind,
and delaying it makes the eventual freeze vacuum larger.

## Lab results

Tested on PostgreSQL 16, Ubuntu 24.04, against a local lab database.
A 5,000 row table with autovacuum disabled for the table had 2,000
rows deleted, leaving 3,000 live and 2,000 dead tuples (40 percent).
The script flagged it VACUUM RECOMMENDED at the default thresholds
and listed it as NEVER VACUUMED. With `-v warn_dead_pct=90` the same
table reported OK, confirming the threshold override works, and with
`-v min_unused_index_mb=0` its never-scanned customer index
appeared in the review list. A held transaction (an open transaction
running `pg_sleep`) appeared in the horizon section while it was
open. After a manual `VACUUM`, the dead count fell to zero, the
status returned to OK, and the table shrank from 472 kB to 384 kB.
