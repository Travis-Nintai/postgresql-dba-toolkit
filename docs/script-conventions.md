# Script conventions

Conventions used by every SQL and shell script in this repository. They exist
so a script behaves the same way whether it is run by hand at 2 AM or from a
scheduler.

## SQL (psql) scripts

- Read-only unless the filename says otherwise. Diagnostic scripts never write.
- A header comment states the purpose, the exact `psql` invocation, and which
  PostgreSQL version the script was tested against.
- Tunables use psql variables with conditional defaults at the top of the
  script (`\if :{?var} \else \set var <default> \endif`), so a default applies
  only when the variable was not passed with `psql -v`. Command-line `-v`
  always wins; nobody has to edit the script to tune a threshold.
- `\pset border 2` and `\pset null '(null)'` keep output readable.
- Sections are separated with `\echo` banners so log files stay scannable.
- Never embed credentials, hostnames, or environment-specific values.
  Connections come from libpq environment variables (`PGHOST`, `PGPORT`,
  `PGUSER`, `PGDATABASE`, `PGPASSWORD`) or `psql` flags.
- Queries target catalog and statistics views (`pg_stat_activity`,
  `pg_stat_replication`, `pg_locks`, `pg_database`) and are written for the
  PostgreSQL version named in the header.

## Shell scripts

- `set -u` so unset variables fail loudly.
- Named flags with `getopts`; `-h` prints usage.
- Connection parameters default to the libpq environment variables, so the same
  script works locally and in automation without edits.
- Every run writes a timestamped log under `logs/`.
- Exit codes are documented in the header and stay stable:
  - `0`: the check ran successfully
  - `1`: usage error
  - `2`: could not connect to PostgreSQL
  - `3`: the SQL script reported an error
- A connectivity probe runs before the real script so a dead database produces
  exit code 2, not a confusing SQL failure.
- `psql` runs with `ON_ERROR_STOP=1` so the first SQL error stops the script
  instead of letting later sections run on a broken session.
