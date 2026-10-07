# Snapshot CDC delta pattern

A Snowflake pattern, packaged as a skill, for feeding reverse ETL jobs a stable stream of changes
from data that is still being curated and renamed upstream.

## The problem

Reverse ETL jobs need to know what changed since they last ran: new records, changed records and
removed records. The awkward part is that upstream data keeps moving. Columns get renamed, logic
gets curated, sources get swapped. Meanwhile the destination system has fixed column names that
nobody wants to change. I hit this repeatedly in my own data engineering work, saw it was the same
problem each time, and formalised the answer into one repeatable pattern rather than solving it
again per feed.

## The core idea: two stable contracts

The change detection is deliberately naive. It never tries to understand renames or schema drift.
Instead it sits between two contracts that don't move:

- **Upstream, a curated source view.** Renames and curation are absorbed here, once. If an upstream
  column is renamed, the view is redefined and nothing downstream notices.
- **Downstream, a fixed destination schema.** The delta table's columns match what the destination
  expects.

Everything in between only compares what the view says today with what it said yesterday.

## What it builds

For one use case, the skill generates four tables, five procedures and a task graph:

| Object | Role |
|---|---|
| `{USE_CASE}_BASE` | Current state, with a record hash and soft-delete flags |
| `{USE_CASE}_CHANGE_HISTORY` | Field-level audit: which field changed, old value, new value |
| `{USE_CASE}_DELTA` | Append-only, `ACTION`-tagged rows (`UPSERT` or `DELETE`) the consumer polls by `INSERT_DATE` |
| `{USE_CASE}_SNAPSHOT` | Previous known-good state, for investigation |
| `CDC_AUDIT.CDC_RUN_LOG` | Every run, with counts and status, shared across use cases |
| Daily task graph | Upsert, then delta, then snapshot |
| Weekly housekeeping task | Retention for history and delta, and hard purge of delivered deletes |

Design decisions worth knowing:

- **Deletes travel with everything else.** A removed record arrives in the same delta table with
  `ACTION = 'DELETE'` and its last-known values, so the consumer has one feed to read, not two to
  reconcile.
- **Retention is part of the design.** Change history (default 365 days), delta (default 90, which
  is also the longest outage a consumer can recover from without a reload) and a soft-delete grace
  period (default 30) are inputs, not afterthoughts.
- **Safe to re-run.** Upsert and delta each skip if they already succeeded for the date, and each
  commits all its writes together or none.
- **A delete can't be lost.** Housekeeping only hard-purges a soft-deleted row once its DELETE is
  confirmed in the delta table, and refuses to run if the grace period isn't shorter than delta
  retention.

The full specification is in [`references/pattern-design.md`](references/pattern-design.md),
including why this uses snapshot comparison rather than Streams or Dynamic Tables, and where it
doesn't apply.

## Verified live

[`examples/customer_profile/`](examples/customer_profile/) is a complete instance on an invented
customer dataset. It replays five days of upstream change: an update and a new customer, an
upstream column rename absorbed by the view (zero changes produced), two deletes delivered with
last-known values, a retry correctly skipped, a deleted customer returning, then housekeeping six
weeks later. Run in a Snowflake trial account on 7 October 2026, all 19 checks in
`04_assertions.sql` passed; the result is saved as
[`verified-run-2026-10-07.csv`](examples/customer_profile/verified-run-2026-10-07.csv).

To run it yourself: run `01_setup.sql` to `04_assertions.sql` in order in a worksheet, then
`99_teardown.sql` to remove everything. It uses its own `CDC_DEMO` database and an extra-small
warehouse, and creates its tasks suspended so nothing runs on a schedule.

## Verified in Cortex Code

Loaded as a workspace skill in Cortex Code in Snowsight on 7 October 2026 and invoked with
`/snowflake-cdc-delta-pattern` on a request for a product-data delta table. It read the pattern
design and the worked example, led with the view-as-contract principle, and started gathering the
required inputs (source view first) before generating anything, as the skill instructs.

## Known limits (v1)

- Single-column primary keys only. Expose a surrogate key in the source view if the natural key is
  composite.
- Daily batch cadence. For near-real-time change, use Streams or Dynamic Tables.
- Tested in Cortex Code in Snowsight by explicit invocation (`/snowflake-cdc-delta-pattern`). Whether
  it triggers on its own from a plain request, without the slash command, hasn't been tested.
