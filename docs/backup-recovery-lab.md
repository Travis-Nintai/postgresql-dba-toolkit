# Backup and recovery lab (PostgreSQL)

PostgreSQL gives you two different backup tools, and they solve different
problems. Logical backups (`pg_dump`) export one database as SQL or as an
archive you can restore selectively. Physical backups (`pg_basebackup`) copy
the whole cluster at the file level and are the foundation for point-in-time
recovery (PITR). A DBA who only knows one of them has half a recovery plan.

This lab walks through both on a local instance, then restores and verifies.
Everything was run in a local test environment with fictional data. Host
`db.example.local` appears in examples as a placeholder; the actual lab ran
on a local socket.

## What you need

- PostgreSQL 10 or later (tested on PostgreSQL 16, Ubuntu 24.04)
- A scratch database you are allowed to destroy (`labdb` below)
- Enough disk for two copies of the test data

## Part 1: logical backup and restore

### Create test data

```sql
CREATE DATABASE labdb;
\c labdb
CREATE TABLE lab_orders (
    order_id   integer PRIMARY KEY,
    customer   text NOT NULL,
    total      numeric(10,2) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO lab_orders (order_id, customer, total)
SELECT g, 'customer_' || g, (g % 500) + 9.99
FROM generate_series(1, 10000) AS g;
```

### Back up

Use the script in this repo, which wraps `pg_dump` with a connectivity probe
and verifies the archive by reading it back with `pg_restore --list`:

```
bash/backup_database.sh -d labdb -o ./backups
```

The manual equivalent, for when the script is not handy:

```
pg_dump -d labdb --format=custom --file=backups/labdb.dump
pg_restore --list backups/labdb.dump > /dev/null && echo "archive readable"
```

Formats, briefly: custom (`c`) is compressed and restorable in parallel or
selectively, and is the right default. Directory (`d`) allows parallel dump
and restore. Plain (`p`) is a SQL text file, useful for inspection and for
moving a small database by hand. Tar (`t`) exists mostly for compatibility.

### Restore into a second database

Never rehearse a restore over the original. Restore beside it and compare.

```
createdb labdb_restore
pg_restore -d labdb_restore backups/labdb.dump
```

### Verify

Row counts are necessary but not sufficient; compare an aggregate that
would catch changed values too:

```sql
SELECT count(*), sum(total), min(order_id), max(order_id) FROM lab_orders;
```

Run it in both databases. Count, sum, min, and max must match exactly. For a
stronger check on real (but non-sensitive) data, compare a hash aggregate
over ordered rows, or restore one known table and diff a full export.

## Part 2: physical base backup

`pg_basebackup` copies the entire cluster, all databases, while it runs.
The connecting role needs the REPLICATION attribute (or superuser), and
`pg_hba.conf` needs a replication entry for it.

```
pg_basebackup -D backups/base_20261022 -Ft -z -P -X stream -c fast
```

- `-Ft -z`: tar format, compressed. Plain format (`-Fp`) is what you want
  when the copy itself is the standby's starting point.
- `-X stream`: stream the WAL generated during the backup so the copy is
  self-consistent without waiting for archived segments.
- `-c fast`: take the start checkpoint immediately. The default, spread,
  waits for the next scheduled checkpoint, which on an idle system can
  mean minutes of doing nothing for no benefit. In production, spread is
  the gentler choice on a busy cluster; know which one you picked.
- `-P`: progress reporting. Base backups of real clusters take real time.

A base backup alone restores the cluster to the moment the backup
*finished*. To restore to an arbitrary moment, you also need the WAL
generated after the backup, which is Part 3.

## Part 3: WAL archiving and point-in-time recovery

PITR = base backup + replay of archived WAL up to a chosen target time,
transaction, or restore point. The configuration that makes it possible has
to be in place *before* the incident:

```ini
# postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/archive/%f && cp %p /var/lib/postgresql/archive/%f'
```

`archive_command` must return success only when the segment is safely
stored. If it reports success and the file is not really there, the gap
will be discovered during recovery, which is the worst possible time.

### Recovery walkthrough (concepts and sequence)

1. Stop the cluster. Preserve the current `PGDATA` and any unarchived WAL
   before touching anything; the broken state is evidence and sometimes
   recoverable data.
2. Restore the base backup into a fresh data directory.
3. Configure recovery in `postgresql.conf` (PostgreSQL 12 and later):

   ```ini
   restore_command = 'cp /var/lib/postgresql/archive/%f %p'
   recovery_target_time = '2026-10-22 09:15:00'
   ```

4. Signal recovery by creating the `recovery.signal` file in the data
   directory, then start the server. It replays WAL from the archive up to
   the target and then promotes itself.
5. Verify the recovered state (the same count and aggregate comparisons as
   Part 1, plus application-level spot checks), then take a fresh base
   backup of the recovered cluster before calling it done.

Differences worth knowing: `recovery_target_action` can pause at the
target instead of promoting, so you can connect read-only (hot standby
during recovery requires `hot_standby = on`) and confirm you stopped at the
right moment before committing to it. Named restore points
(`pg_create_restore_point`) give you targets you can choose in advance,
before a risky migration or batch job, instead of reconstructing a
timestamp afterward.

## Lab verification record

This lab was executed on PostgreSQL 16 (Ubuntu 24.04) in October 2026 with
the exact steps above. Results:

- Test database `labdb` created; `lab_orders` loaded with 10,000 rows.
- `bash/backup_database.sh -d labdb` exited 0 and produced a custom-format
  archive (about 60 KB); the script's `pg_restore --list` verification
  passed with 18 archived objects.
- Archive restored into a second database, `labdb_restore`.
- Verification query results matched exactly between source and restore:
  count 10,000, sum 2594900.00, min order_id 1, max order_id 10000, and a
  spot-checked row was identical, including its timestamp.
- Exit-code checks: usage error (no `-d`) exits 1; unreachable host
  exits 2.
- The base backup (Part 2) was taken with `pg_basebackup -X stream -c fast`
  and completed: `base.tar.gz`, `pg_wal.tar.gz`, and `backup_manifest`
  were produced.

The full PITR replay in Part 3 is documented as a walkthrough; the
archive-and-replay cycle was not executed end to end in this stage of the
lab, and this document does not claim otherwise.

## Failure modes worth rehearsing

- **Restoring into the wrong database.** `pg_restore -d` does not ask
  twice. Named targets and a second pair of eyes on the command line.
- **A gap in archived WAL.** Recovery stops at the end of the available
  segments, before your target. Nothing fixes a segment that was never
  archived; monitor archiving (`pg_stat_archiver`) before you need it.
- **Backups nobody has restored.** The archive listing check catches
  truncation and corruption early, but only a real restore proves the
  backup. Schedule restore drills, not just backups.

## Related material

- `bash/run_sql_check.sh`: the repo's runner conventions (logging, stable
  exit codes) that `backup_database.sh` follows.
- `docs/script-conventions.md`: the conventions both scripts follow.
- `docs/blocking-session-runbook.md`: a different kind of bad day.
