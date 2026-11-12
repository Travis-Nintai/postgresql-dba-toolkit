# EXPLAIN ANALYZE Query Tuning: A Worked Lab Example

Two slow queries, two indexes, and one trap. Everything here was run
against a local lab database, and the plans below are the actual output
from that run, not reconstructed examples. Timings vary from run to run;
the shapes of the plans and the size of the improvements are the point,
not the third decimal place.

## The lab

`sql/query_tuning_lab_setup.sql` builds the data. It creates
`lab_orders` (100,000 rows: 5,000 customers, dates across 2025, five
statuses) and `lab_order_items` (300,000 rows, three line items per
order), with only the primary keys indexed. Run it once in a scratch
database:

```
createdb labdb
psql -h db.example.local -U dba -d labdb -f sql/query_tuning_lab_setup.sql
```

The script uses a fixed random seed, so the data distribution is the
same every time it runs. The setup script is the one file in `sql/`
that writes data; the diagnostic scripts stay read-only. After the
load, the tables are analyzed, so the planner has current statistics.
If you load data any other way, run `ANALYZE` on the tables before
trusting a plan: stale statistics are the most common reason a plan
looks wrong for no good reason.

## Reading a plan

`EXPLAIN` shows the plan the planner chose and its cost estimates.
`EXPLAIN ANALYZE` runs the query and adds what actually happened.
Always use the ANALYZE form when tuning; the estimate alone hides the
two things that matter, how long each node really took and how many
rows it really returned. Note that ANALYZE executes the query, so
never run it on a statement that writes data unless you intend the
write. `BUFFERS` adds the page traffic, which is how you tell a plan
that was fast because the data was cached from one that is actually
cheap.

The fields worth reading on every node:

- `cost`: the planner's estimate, in arbitrary units. The first number
  is the cost before the first row, the second is the cost for all
  rows. Only compare costs between plans for the same query; a cost of
  2,400 on one machine means nothing next to a cost of 2,400 on
  another.
- `actual time`: milliseconds to first row, then to last row, per loop.
  This is the real number.
- `rows`: estimated rows, then actual rows. When the estimate is far
  from the actual count, the planner is working from bad statistics or
  a predicate it cannot estimate, and the plan choice may be wrong for
  that reason alone.
- `loops`: how many times the node ran. Multiply `actual time` and
  `rows` by loops to get the node's real contribution. A node that
  looks cheap at 0.02 ms is not cheap if it ran 100,000 times.
- `Buffers: shared hit`: pages read from the shared buffer cache.
  `read` is pages fetched from disk. A plan that touches 878 pages to
  return 20 rows is doing far more work than one that touches 23.
- `Planning Time`: usually a fraction of a millisecond. If it ever
  dominates execution time, the query is either trivial or the
  planning itself is the problem (many partitions, many joins).

## Case 1: recent shipped orders, sorted

A dashboard query: the 20 most recent shipped orders since November 1.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, order_date, amount
FROM lab_orders
WHERE status = 'shipped'
  AND order_date >= '2025-11-01'
ORDER BY order_date DESC
LIMIT 20;
```

### Before: sequential scan plus sort

```
Limit  (cost=2461.59..2461.64 rows=20 width=26) (actual time=8.597..8.602 rows=20 loops=1)
  Buffers: shared hit=878
  ->  Sort  (cost=2461.59..2469.72 rows=3254 width=26) (actual time=8.595..8.598 rows=20 loops=1)
        Sort Key: order_date DESC
        Sort Method: top-N heapsort  Memory: 27kB
        Buffers: shared hit=878
        ->  Seq Scan on lab_orders  (cost=0.00..2375.00 rows=3254 width=26) (actual time=0.009..8.096 rows=3263 loops=1)
              Filter: ((order_date >= '2025-11-01 00:00:00+00'::timestamp with time zone) AND (status = 'shipped'::text))
              Rows Removed by Filter: 96737
              Buffers: shared hit=875
Planning Time: 0.146 ms
Execution Time: 8.623 ms
```

Read it bottom up. The sequential scan reads all 100,000 rows and
throws away 96,737 of them. The estimate (3,254 rows) is close to the
actual count (3,263), so the statistics are fine; the planner simply
has no better access path, because no index covers `status` or
`order_date`. The sort then orders the 3,263 survivors to find the
top 20. `top-N heapsort` is the planner being efficient about the
LIMIT, it keeps only the best 20 rows in memory, but it still has to
look at all 3,263 to know which 20 those are. Total: 8.6 ms, 878
buffer hits. On a table this size that is not a disaster; on a table
with ten million rows the same shape is a full scan and a sort on
every dashboard refresh.

### The fix: one composite index, ordered to match the query

```sql
CREATE INDEX idx_lab_orders_status_order_date
    ON lab_orders (status, order_date DESC);
```

The column order matters. `status` first because it is the equality
predicate, the part that narrows the search to one slice of the
index. `order_date DESC` second because it matches the ORDER BY, so
rows come out of the index already in the order the query wants and
the sort disappears entirely.

### After: index scan, no sort

```
Limit  (cost=0.42..22.23 rows=20 width=26) (actual time=0.049..0.085 rows=20 loops=1)
  Buffers: shared hit=20 read=3
  ->  Index Scan using idx_lab_orders_status_order_date on lab_orders  (cost=0.42..3549.52 rows=3254 width=26) (actual time=0.048..0.081 rows=20 loops=1)
        Index Cond: ((status = 'shipped'::text) AND (order_date >= '2025-11-01 00:00:00+00'::timestamp with time zone))
        Buffers: shared hit=20 read=3
Planning Time: 0.338 ms
Execution Time: 0.106 ms
```

The index scan walks straight to the shipped slice, reads the newest
20 rows in index order, and stops. No scan, no sort. Execution time
fell from 8.6 ms to 0.11 ms, and buffer traffic from 878 pages to 23.
A second run confirmed the result (9.7 ms before, 0.15 ms after).
Note the total plan cost estimate (3,549.52) is higher than the
before plan's cost (2,461.59), which looks wrong until you read the
LIMIT cost: the planner charges the index scan for all 3,254 matching
rows, but the LIMIT stops it after 20, so the startup cost of 0.42
and the per-row cost are what actually apply. Cost is a guide, not a
measurement; `actual time` is the measurement.

## Case 2: line items for one customer, missing foreign key index

A customer service query: every line item on every order for one
customer, newest first. The customer has 14 orders and 42 line items.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.order_date, i.product_sku, i.qty, i.unit_price
FROM lab_orders o
JOIN lab_order_items i ON i.order_id = o.order_id
WHERE o.customer_id = 1234
ORDER BY o.order_date DESC
LIMIT 50;
```

### Before: hash join over two full scans

```
Limit  (cost=7854.12..7858.15 rows=35 width=35) (actual time=37.917..42.599 rows=42 loops=1)
  Buffers: shared hit=4355
  ->  Gather Merge  (cost=7854.12..7858.15 rows=35 width=35) (actual time=37.915..42.592 rows=42 loops=1)
        Workers Planned: 1
        Workers Launched: 1
        Buffers: shared hit=4355
        ->  Sort  (cost=6854.11..6854.20 rows=35 width=35) (actual time=35.873..35.878 rows=21 loops=2)
              Sort Key: o.order_date DESC
              Sort Method: quicksort  Memory: 26kB
              Buffers: shared hit=4355
              Worker 0:  Sort Method: quicksort  Memory: 26kB
              ->  Hash Join  (cost=2125.25..6853.21 rows=35 width=35) (actual time=6.652..35.790 rows=21 loops=2)
                    Hash Cond: (i.order_id = o.order_id)
                    Buffers: shared hit=4298
                    ->  Parallel Seq Scan on lab_order_items i  (cost=0.00..4264.71 rows=176471 width=27) (actual time=0.008..15.451 rows=150000 loops=2)
                          Buffers: shared hit=2500
                    ->  Hash  (cost=2125.00..2125.00 rows=20 width=16) (actual time=6.480..6.481 rows=14 loops=2)
                          Buckets: 1024  Batches: 1  Memory Usage: 9kB
                          Buffers: shared hit=1750
                          ->  Seq Scan on lab_orders o  (cost=0.00..2125.00 rows=20 width=16) (actual time=0.037..6.465 rows=14 loops=2)
                                Filter: (customer_id = 1234)
                                Rows Removed by Filter: 99986
                                Buffers: shared hit=1750
Planning Time: 0.283 ms
Execution Time: 42.648 ms
```

The planner had no index on `lab_order_items.order_id`, so the only
way to join was to scan the whole items table (300,000 rows across
two parallel workers, 150,000 each) and hash it against the 14 orders
for this customer. The join itself is not the problem; the problem is
that finding 42 rows required reading 300,000. PostgreSQL does not
create indexes on foreign keys automatically, which is the most common
version of this mistake: the `REFERENCES` clause enforces the
relationship, it does not index it. Total: 42.6 ms, 4,355 buffer hits.

### The fix: index the foreign key

```sql
CREATE INDEX idx_lab_order_items_order_id
    ON lab_order_items (order_id);
```

### After: nested loop with index lookups

```
Limit  (cost=2439.53..2439.66 rows=50 width=35) (actual time=6.787..6.796 rows=42 loops=1)
  Buffers: shared hit=944 read=15
  ->  Sort  (cost=2439.53..2439.68 rows=60 width=35) (actual time=6.786..6.790 rows=42 loops=1)
        Sort Key: o.order_date DESC
        Sort Method: quicksort  Memory: 27kB
        Buffers: shared hit=944 read=15
        ->  Nested Loop  (cost=0.42..2437.76 rows=60 width=35) (actual time=0.070..6.763 rows=42 loops=1)
              Buffers: shared hit=944 read=15
              ->  Seq Scan on lab_orders o  (cost=0.00..2125.00 rows=20 width=16) (actual time=0.050..6.504 rows=14 loops=1)
                    Filter: (customer_id = 1234)
                    Rows Removed by Filter: 99986
                    Buffers: shared hit=875
              ->  Index Scan using idx_lab_order_items_order_id on lab_order_items i  (cost=0.42..15.61 rows=3 width=27) (actual time=0.014..0.017 rows=3 loops=14)
                    Index Cond: (order_id = o.order_id)
                    Buffers: shared hit=69 read=15
Planning Time: 0.395 ms
Execution Time: 6.818 ms
```

The planner switched to a nested loop: for each of the 14 orders it
does one index lookup into the items table, 3 rows per lookup, 14
loops. Execution time fell from 42.6 ms to 6.8 ms, buffer traffic
from 4,355 pages to 944. A second run confirmed it (43.0 ms before,
7.1 ms after).

But read the plan honestly: the fix is incomplete. The nested loop
is fast, but the outer side is still a sequential scan of all
100,000 orders to find the 14 for this customer, and that scan is
6.5 ms of the 6.8 ms total. The remaining cost is the unindexed
`customer_id` filter, not the join. Adding an index on
`lab_orders (customer_id)` was tested as a follow-up and took the
same query to 0.27 ms, with a bitmap index scan replacing the outer
sequential scan. That index was dropped again after the test because
the lab's point is the foreign key case, but the number is real: each
missing index is its own problem, and fixing one exposes the next.

## Case 3: the trap, a function on the indexed column

With the case 1 index in place, the same query written with a
function on the indexed column ignores the index completely:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, customer_id, order_date, amount
FROM lab_orders
WHERE lower(status) = 'shipped'
  AND order_date >= '2025-11-01'
ORDER BY order_date DESC
LIMIT 20;
```

```
Limit  (cost=2627.21..2627.26 rows=20 width=26) (actual time=12.392..12.397 rows=20 loops=1)
  Buffers: shared hit=875
  ->  Sort  (cost=2627.21..2627.42 rows=83 width=26) (actual time=12.391..12.393 rows=20 loops=1)
        Sort Key: order_date DESC
        Sort Method: top-N heapsort  Memory: 27kB
        Buffers: shared hit=875
        ->  Seq Scan on lab_orders  (cost=0.00..2625.00 rows=83 width=26) (actual time=0.049..11.877 rows=3263 loops=1)
              Filter: ((order_date >= '2025-11-01 00:00:00+00'::timestamp with time zone) AND (lower(status) = 'shipped'::text))
              Rows Removed by Filter: 96737
              Buffers: shared hit=875
Planning Time: 0.068 ms
Execution Time: 12.410 ms
```

The index is on `status`; the query filters on `lower(status)`, a
different expression, so the index cannot answer it and the planner
falls back to the sequential scan and sort: 12.4 ms, slower than the
original query was before any index existed. Two things to notice.
First, the estimate is badly wrong here: the planner guessed 83 rows
and got 3,263, because it keeps no statistics on the expression
`lower(status)`. A wrong estimate that large can push the planner
toward the wrong plan on a bigger table, and it is a sign the query
is written in a way the planner cannot reason about. Second, the fix
depends on what the query actually needs. If the column is always
stored lowercase, write `status = 'shipped'` and use the plain index.
If the data really is mixed case and the query must match any case,
build an expression index on `(lower(status), order_date DESC)` so
the index matches the query exactly. Do not fix this by disabling
sequential scans; `SET enable_seqscan = off` only hides the planner's
reasoning, it does not make the query fast, and it changes plan
choices for the whole session.

## What to check before adding an index

- Confirm the query is actually slow, and that the slow part is
  access, not something else. A plan dominated by a sort of millions
  of rows, a hash join over a full table, or a sequential scan with
  most rows removed by filter is an access problem. A plan dominated
  by a single node returning one row slowly is usually a lock, a
  function call, or I/O, and an index will not help.
- Check the row estimates against actual rows. A large gap means
  stale statistics (run `ANALYZE`) or a predicate the planner cannot
  estimate (a function, a complex expression, a skewed column). Fix
  the estimate before trusting the plan choice.
- Match the index to the query: equality columns first, then range
  columns, then the sort key. An index that covers the filter but not
  the sort still sorts; an index that covers the sort but not the
  filter still scans.
- Weigh the write cost. Every index slows inserts, updates, and
  deletes on the table and takes space. The two indexes in this lab
  are small; on a write-heavy table with ten indexes, the eleventh
  needs a better reason than a query that runs once a day.
- Re-run `EXPLAIN ANALYZE` after creating the index. The planner
  sometimes keeps the old plan because the new index is not actually
  better for that query, and that is information, not a failure.

## Lab results

Tested on PostgreSQL 16.15, Ubuntu 24.04, local lab database
(`labdb`, 100,000 orders, 300,000 line items). Each query was run
twice; the plans above are from the first run and the second run
matched within a millisecond.

| Query | Before | After | Change |
|---|---|---|---|
| Case 1: recent shipped orders | 8.6 ms, 878 buffers, seq scan plus sort | 0.11 ms, 23 buffers, index scan, no sort | About 80x faster |
| Case 2: line items for one customer | 42.6 ms, 4,355 buffers, hash join over two scans | 6.8 ms, 944 buffers, nested loop with index lookups | About 6x faster |
| Case 2 follow-up: plus a customer index | 6.8 ms | 0.27 ms | About 25x faster again |
| Case 3: function on the indexed column | 12.4 ms, seq scan, index ignored | No index change fixes it; rewrite the predicate or build an expression index | Trap, not a tuning win |

The lab database and the indexes were created for this test only.
The lab tables were dropped after testing, and the indexes exist
only inside the lab database, not in the repository.
