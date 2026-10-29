# Streaming Replication Setup and Monitoring

How to stand up a PostgreSQL streaming replica with `pg_basebackup`, how
to watch it with `sql/replication_status.sql`, and what to check when lag
grows or a standby disappears. This is the asynchronous setup most teams
start with: one primary, one or more read-only standbys, with promotion
as a manual, deliberate step.

## What streaming replication gives you, and what it does not

A standby receives WAL records from the primary as they are generated and
replays them, so it stays close behind the primary without shared storage
or a third-party tool. It is a solid read scaling and disaster recovery
building block. It is not automatic failover: nothing in this setup
promotes a standby on its own, and nothing here reroutes application
traffic. If you need that, it is a separate layer (a failover manager or
orchestrator), and it deserves its own design and testing.

## Primary configuration

These settings live in `postgresql.conf` (or `ALTER SYSTEM`, which writes
`postgresql.auto.conf`). `max_wal_senders` needs a restart; the rest take
effect on reload.

| Setting | Value | Why |
|---|---|---|
| `wal_level` | `replica` | The default on current versions, but set it explicitly so a future config change cannot silently break replication. |
| `max_wal_senders` | at least the number of standbys plus one | Each standby holds one WAL sender process. Leave headroom for a base backup running at the same time. |
| `wal_keep_size` | `256MB` to start | WAL retained on the primary for a disconnected standby. Too small and a standby that falls behind has to be rebuilt; too large and disk fills. Size it from your real write rate, not from this example. |
| `listen_addresses` | the primary's address | The standby has to reach the primary over TCP. `localhost` is fine for a lab on one host, never for a real pair. |

Create a dedicated replication role. It needs no login to ordinary
databases and no superuser privilege:

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '<password>';
```

Put the password in `.pgpass` on the standby host, not in a script or a
committed config file. The standby's `primary_conninfo` will contain it
otherwise, since `pg_basebackup -R` writes that string into the standby's
configuration.

Allow the standby to connect in `pg_hba.conf` on the primary:

```
host replication replicator <STANDBY_CIDR> scram-sha-256
```

The database field must be `replication`, not `all`: a host line for
`all` does not match replication connections.

## Building the standby

From the standby host, with the primary running:

```
pg_basebackup -h <PRIMARY_HOST> -p 5432 -U replicator \
  -D /var/lib/postgresql/replica -R -X stream -C -S <SLOT_NAME> -P -v
```

What the flags do:

- `-R` writes `standby.signal` and `primary_conninfo` into the new data
  directory, so the copy starts as a replica instead of a second primary.
- `-X stream` streams WAL generated during the backup, so the standby
  starts up to date instead of needing WAL files chased down afterward.
- `-C -S <SLOT_NAME>` creates a physical replication slot on the primary.
  The slot pins WAL on the primary until the standby consumes it, which
  protects a briefly disconnected standby from needing a rebuild. The
  price is disk: a standby that stays down holds WAL on the primary
  indefinitely, so monitor slots, not just lag.
- `-P -v` shows progress. A base backup of a large database takes a
  while; the progress output is how you know it is moving.

Two packaging gotchas worth knowing. First, `pg_basebackup` copies the
data directory, not the configuration files that some distributions keep
elsewhere, so a standby built from such a primary needs its own
`postgresql.conf` (port, `hot_standby = on`) and `pg_hba.conf` before it
will start. Second, the standby inherits the primary's
`postgresql.auto.conf`, including `max_wal_senders`: if that value is
lower than the primary's running value, the standby refuses to start and
says so in its log. Both showed up during lab testing and both are
fixed by editing the standby's own files, never the primary's.

Start the standby and confirm it is streaming before trusting it:

```
pg_ctl -D /var/lib/postgresql/replica -l replica.log start
```

Then run `sql/replication_status.sql` against the primary. A healthy
pair shows one row in `pg_stat_replication` with state `streaming` and
small or zero lag on every measure, and the replica side shows a WAL
receiver connected with matching replay lag. Write a row on the primary
and read it back on the replica: that end-to-end check is worth more
than any single lag number.

## Monitoring with replication_status.sql

```
psql -h <PRIMARY_HOST> -U <user> -d postgres -f sql/replication_status.sql
psql -h <STANDBY_HOST> -U <user> -d postgres -f sql/replication_status.sql
```

The script works on either side and says which side it is on. On a
primary it lists each standby with send, write, flush, and replay lag
and flags any standby past the threshold:

```
psql -h <PRIMARY_HOST> -U <user> -d postgres \
  -v max_replay_lag_mb=16 -f sql/replication_status.sql
```

The four lag measures answer different questions. Send lag is WAL the
primary has generated but not yet sent. Write lag is WAL sent but not
yet written on the standby. Flush lag is WAL written but not yet
durable. Replay lag is WAL durable on the standby but not yet applied,
and it is the one users on the standby would notice, since a read-only
query on the standby sees data only up to the replay point. For
failover planning, replay lag is the number that matters.

On a replica the script reports the WAL receiver connection and the
gap between received and replayed WAL. If the instance is in recovery
with no WAL receiver row, the standby is not connected to its primary
at all, which is a different problem from lag and needs attention
first.

Replication slots get their own section. Watch two things: a slot that
is no longer `active` (its standby is gone or renamed) and retained WAL
growing without bound (a standby that is connected but not consuming,
or a slot left behind after a standby was decommissioned). Drop slots
for standbys that will never return; an orphaned slot is a slow disk
incident.

## Synchronous replication, briefly

By default this setup is asynchronous: the primary commits without
waiting for any standby. That is the right default for most read
replicas. If a standby must never fall behind a commit, set
`synchronous_standby_names` on the primary to name the standby (set
`application_name` in the standby's `primary_conninfo` so the name is
recognizable; the default is `walreceiver`) and confirm the standby
reports `sync_state = sync` in `pg_stat_replication`. Synchronous
replication trades commit latency and primary availability for zero
data loss on failover, so test it under load before promising it.

## Promotion

Promoting a standby is a deliberate act, not a monitoring event:

1. Stop writes to the primary if it is still reachable, and confirm the
   standby has replayed up to the last available WAL.
2. Run `pg_ctl promote` on the standby, or remove `standby.signal` and
   reload. The standby leaves recovery and accepts writes.
3. Point applications at the promoted instance and re-point any
   remaining standbys at it, which means rebuilding them from the new
   primary. A standby cannot simply follow a promoted peer.
4. Take a fresh backup of the promoted primary as soon as the dust
   settles. The old backup chain belongs to the old primary.

Never promote both sides. A split brain with writes on two primaries is
harder to repair than any outage it was meant to shorten.

## Troubleshooting

| Symptom | Likely cause | Check first |
|---|---|---|
| No row in `pg_stat_replication` | Standby never connected | `pg_hba.conf` replication line on the primary; `primary_conninfo` on the standby; standby log for connection errors. |
| State stuck at `startup` or `catchup` | Standby is far behind | Wait and watch replay lag fall; if it never falls, the standby is not keeping up with the write rate. |
| Replay lag growing steadily | Standby cannot replay fast enough, or replay is paused | `pg_stat_wal_receiver` status; `pg_wal_replay_pause()` state on the standby; long-running queries on the standby blocking replay (a hot standby conflict). |
| Slot retained WAL growing | Standby down or not consuming | Slot `active` flag; standby process state; drop the slot if the standby is decommissioned. |
| Standby refuses to start, `max_wal_senders` error | Inherited config lower than the primary's | The standby's own `postgresql.auto.conf`, not the primary's. |
| Standby refuses to start, missing `pg_hba.conf` | Config lives outside the data directory on the primary's distribution | Write the standby's own `pg_hba.conf` and `postgresql.conf`. |
| Failover target missing recent transactions | Asynchronous replication, by design | Replay lag at promotion time; this is why promotion checks replay position before accepting writes. |

## Lab verification

Tested on PostgreSQL 16.15, Ubuntu 24.04, with a primary on port 5432
and a standby on port 5434 built by `pg_basebackup -R -X stream -C -S`
on the same host, using fictional lab data only:

- Standalone run first: the script reported "No standbys connected" on
  the primary side and "n/a - this instance is a primary" on the
  replica side, with no errors.
- After the standby started streaming, the primary side showed one
  standby in state `streaming`, `sync_state` async, all four lag
  measures at 0 bytes, and the slot active with 0 bytes retained WAL.
  The replica side showed the WAL receiver connected with 0 bytes
  replay lag.
- A 200 row lab table matched exactly on both sides (count 200, sum
  211050.00).
- Paused replay test: with replay paused on the standby, 200 more rows
  were written on the primary. The script, run with
  `-v max_replay_lag_mb=0`, flagged the standby WARNING with 31 kB
  replay lag, while the replica still returned the old 200 rows.
  After replay resumed, both sides matched again at 400 rows, sum
  842100.00.

## Assumptions

- The script uses only long-stable catalog and statistics views
  (`pg_stat_replication`, `pg_stat_wal_receiver`,
  `pg_replication_slots`) and was tested on PostgreSQL 16. It should
  run on any currently supported version, but that is not verified
  here.
- Run as a user that can read `pg_stat_replication`,
  `pg_stat_wal_receiver`, and `pg_replication_slots`. A superuser
  works; a dedicated monitoring role with `pg_monitor` granted is
  the better production answer.
- Connection details come from libpq environment variables or
  command-line flags. No credentials in scripts, logs, or the
  repository.
