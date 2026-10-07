# Snapshot-Based Change Data Capture Pattern

## 0. The Core Insight

This pattern does not try to be clever about upstream schema change. It deliberately does not have to be.

The source view is the enforced contract. Curation, column renaming, and business logic changes happen exactly once, at the view layer, before anything reaches the CDC objects. The CDC mechanism downstream is naive by design: it compares whatever the view hands it today against whatever it handed it yesterday. It never needs to know that a column used to be called something else.

On the other end, the destination is a set of objects where column names do not and cannot change. So the pattern sits between two stable contracts: a curated view upstream, a fixed schema downstream. That is what makes it survive real-world upstream change without special-case logic for renames. The complexity of "what changed and what do we call it" is resolved once, at the boundary, not repeatedly inside the CDC engine.

Everything below is the mechanics of how that comparison, tracking, and delivery work. Section 8 states the view's role as a prerequisite. It is not a footnote, it is the reason the rest of this works.

---

## 1. Overview

This document describes a **snapshot-based CDC (Change Data Capture) pattern** for detecting and delivering incremental data changes from an upstream source to a downstream integration layer.

The pattern is designed for scenarios where:

- An upstream source (view or table) is refreshed by ETL processes, but does not natively expose change events or timestamps you can trust.
- A downstream integration tool polls for changed records on a schedule and expects a "delta" table containing new, modified, and removed rows.
- Field-level change auditing is required, not just *that* a record changed, but *which fields* changed and what their previous values were.
- The solution must be operationally simple, using only standard SQL objects (tables, views, procedures, tasks).

### When to Use This Pattern

- Source data arrives via batch ETL (not streaming).
- The downstream consumer expects a flat table of changed records, filtered by date.
- You need a persistent, queryable audit trail of every field-level change.
- You want a repeatable, templated approach that can be instantiated for any new data feed.

### When NOT to Use This Pattern

- The source supports native CDC (e.g., Snowflake Streams, database CDC logs). Use those instead.
- Changes are high-frequency (sub-minute). This pattern is designed for daily batch comparison.
- You only need to know *that* a record changed, not *which fields*. A simpler MERGE with RECORD_HASH comparison would suffice.

---

## 2. Architecture

```
 DAILY CYCLE (Task Graph, sequential execution)
 ═══════════════════════════════════════════════════════════════

┌──────────────┐
 │ SOURCE VIEW │ Curated, stakeholder-accepted view
 │ (read-only) │ Columns match expected downstream schema
 └──────┬───────┘
 │
 ▼
 ┌──────────────────────────────────────────────────────────┐
 │ STEP 1: UPSERT PROCEDURE │
 │ │
 │ • Compare SOURCE → BASE (via RECORD_HASH) │
 │ • Log field-level INSERT/UPDATE/DELETE to CHANGE_HISTORY │
 │ • MERGE new & changed records into BASE │
 │ • Soft-delete records from BASE no longer in SOURCE │
 │ • Write run metadata to CDC_RUN_LOG │
 └──────────────────────────┬───────────────────────────────┘
 │ (predecessor)
 ▼
 ┌──────────────────────────────────────────────────────────┐
 │ STEP 2: DELTA PROCEDURE │
 │ │
 │ • Query CHANGE_HISTORY for current run's changed keys │
 │ • Join back to BASE to get full current/last-known rows │
 │ • INSERT into DELTA table (append, no truncation) │
 │ • Tag each row with ACTION = UPSERT or DELETE │
 │ • Coerce NULLs to literal 'null' for downstream compat │
 │ • Write run metadata to CDC_RUN_LOG │
 └──────────────────────────┬───────────────────────────────┘
 │ (predecessor)
 ▼
 ┌──────────────────────────────────────────────────────────┐
 │ STEP 3: SNAPSHOT PROCEDURE │
 │ │
 │ • Truncate SNAPSHOT table │
 │ • Reload from BASE │
 │ • Write run metadata to CDC_RUN_LOG │
 └──────────────────────────┬───────────────────────────────┘
 │ (independent schedule, not a hard predecessor)
 ▼
 ┌──────────────────────────────────────────────────────────┐
 │ HOUSEKEEPING PROCEDURE (weekly) │
 │ │
 │ • Purge CHANGE_HISTORY rows older than retention window │
 │ • Purge DELTA rows older than retention window │
 │ • Hard-delete soft-deleted BASE rows past their grace │
 │ period (their state is already captured downstream) │
 │ • Write run metadata to CDC_RUN_LOG │
 └──────────────────────────────────────────────────────────┘

TABLES:
 ┌───────────┐ ┌────────────┐ ┌─────────────────┐ ┌───────┐
 │ BASE │ │ SNAPSHOT │ │ CHANGE_HISTORY │ │ DELTA │
 │ │ │ (stale │ │ (field-level │ │(append│
 │ +HASH │ │ until │ │ audit trail) │ │ only, │
 │ +IS_DEL │ │ Step 3) │ │ │ │ +ACTION│
 └───────────┘ └────────────┘ └─────────────────┘ └───────┘
 ```

---

## 3. Object Inventory

All objects follow a consistent naming convention using a `{USE_CASE}` identifier (e.g., `CUSTOMER_PROFILE`, `PRODUCT_CATALOGUE`).

### Tables

| Object | Purpose |
|---|---|
| `{USE_CASE}_BASE` | Current-state mirror of the source, plus `RECORD_HASH` and `IS_DELETED` / `DELETED_AT` columns. Updated by the upsert procedure. Soft-deleted rows remain until housekeeping purges them. |
| `{USE_CASE}_SNAPSHOT` | Point-in-time copy of BASE, refreshed as the final step of each daily cycle. Recovery/debug reference representing the previous day's known-good state. Not read by any downstream procedure, kept for manual investigation. |
| `{USE_CASE}_CHANGE_HISTORY` | Append-only audit trail. One row per field per change, with old value, new value, and change type (INSERT / UPDATE / DELETE). Subject to retention. |
| `{USE_CASE}_DELTA` | Append-only table of changed records for downstream consumption, including deletes. Each row is the full current or last-known state of a record, tagged with `ACTION`. Downstream filters by `INSERT_DATE`. Subject to retention. |
| `CDC_RUN_LOG` (shared) | Stored in a dedicated `CDC_AUDIT` schema. Logs every procedure execution with row counts, status, and timestamps. Shared across all CDC use cases. |

### Procedures

| Object | Purpose |
|---|---|
| `SP_{USE_CASE}_INITIAL_LOAD` | One-time bootstrap: populates BASE from source, copies to SNAPSHOT, seeds DELTA with all records as `UPSERT`. |
| `SP_{USE_CASE}_UPSERT` | Daily: compares source to BASE, logs changes to CHANGE_HISTORY, MERGEs into BASE, soft-deletes rows no longer in source. Includes idempotency guard. |
| `SP_{USE_CASE}_DELTA` | Daily: reads today's changes (including deletes) from CHANGE_HISTORY, inserts full current or last-known-state rows into DELTA with `ACTION`. |
| `SP_{USE_CASE}_SNAPSHOT` | Daily: truncates and reloads SNAPSHOT from BASE. |
| `SP_{USE_CASE}_HOUSEKEEPING` | Weekly: purges CHANGE_HISTORY and DELTA rows past retention, hard-deletes soft-deleted BASE rows past their grace period. |

### Tasks (Task Graph)

| Object | Schedule | Predecessors |
|---|---|---|
| `TSK_{USE_CASE}_CDC` | Root task, cron-scheduled (daily) | None (root) |
| `TSK_{USE_CASE}_UPSERT` | Triggered by predecessor | `TSK_{USE_CASE}_CDC` |
| `TSK_{USE_CASE}_DELTA` | Triggered by predecessor | `TSK_{USE_CASE}_UPSERT` |
| `TSK_{USE_CASE}_SNAPSHOT` | Triggered by predecessor | `TSK_{USE_CASE}_DELTA` |
| `TSK_{USE_CASE}_HOUSEKEEPING` | Independent cron (weekly) | None (its own root) |

Housekeeping is deliberately decoupled from the daily chain. It operates on data the daily cycle has already finished with (purged rows are, by definition, older than the retention window), so it has no dependency on same-day success or failure, and a slow or failed housekeeping run should never block or delay the daily delta delivery.

The daily root task triggers its chain. Each subsequent daily task runs only after its predecessor completes successfully. This replaces independent cron schedules for the daily steps, eliminating timing/race condition risk between them.

---

## 4. Data Flow, One Daily Cycle

### Step 0: Starting State

- **BASE** contains yesterday's data (with RECORD_HASH and deletion flags per row).
- **SNAPSHOT** is identical to BASE (refreshed at end of yesterday's cycle).
- **Source view** has been refreshed by upstream ETL overnight.

### Step 1: Upsert (Source -> Base + Change History)

Steps 2 to 8 run inside a single transaction, so a failure part-way through leaves CHANGE_HISTORY and BASE exactly as they were.

1. **Idempotency check**: query CDC_RUN_LOG for a successful run on the same date. If found, skip all processing to prevent duplicates on re-run.
2. **Compute source hashes**: SELECT all rows from the source view, computing `RECORD_HASH = MD5(field1 || '|' || field2 || ... || fieldN)` over all non-key, non-timestamp columns.
3. **Detect UPDATES**: JOIN source to BASE (excluding soft-deleted rows) on primary key. Where both exist but `RECORD_HASH` differs, compare each field individually. For each field that changed, INSERT a row into CHANGE_HISTORY with `CHANGE_TYPE = 'UPDATE'`, old value, and new value.
4. **Detect INSERTS**: LEFT JOIN source to BASE. Where BASE key is NULL, or exists only as a soft-deleted row being revived, INSERT one CHANGE_HISTORY row per field with `CHANGE_TYPE = 'INSERT'`, old value NULL, new value current.
5. **MERGE into BASE**: Upsert all source records into BASE (update changed rows, insert new rows, clear `IS_DELETED` on any revived row). Update `RECORD_HASH` on changed rows.
6. **Detect DELETES**: LEFT JOIN BASE (excluding already soft-deleted rows) to source. Where the source key is NULL, INSERT a single CHANGE_HISTORY row with `CHANGE_TYPE = 'DELETE'`, `FIELD_NAME = 'ALL_FIELDS'`.
7. **Soft-delete in BASE**: Set `IS_DELETED = TRUE`, `DELETED_AT = current_timestamp` on rows whose primary key no longer exists in the source. Do not hard-delete: the row's last-known field values must remain available for Step 2 to deliver to the downstream consumer.
8. **Log to CDC_RUN_LOG**: Record procedure name, use case, timestamp, insert/update/delete counts, status.

### Step 2: Delta Extraction (Change History -> Delta)

1. **Idempotency check**: if CDC_RUN_LOG already has a successful delta run for this date, skip. Without this, a retry would append the same day's rows to DELTA a second time.
2. **Retrieve run timestamp**: query CDC_RUN_LOG for today's upsert run timestamp to ensure delta is tied to the exact same run. If there is no successful upsert for the date, log a failure and stop.
3. **Query CHANGE_HISTORY** for distinct primary keys where `CHANGE_DATE` matches the upsert run timestamp, for all change types (INSERT, UPDATE, DELETE).
4. **JOIN to BASE** on primary key to retrieve the full current or last-known-state row. Soft-deleted rows still resolve correctly here because BASE retains their field values.
5. **Coerce NULLs**: for each VARCHAR column, apply `CASE WHEN col IS NULL THEN 'null' ELSE col END` for downstream compatibility.
6. **Set ACTION**: `'UPSERT'` for INSERT/UPDATE-sourced rows, `'DELETE'` for DELETE-sourced rows.
7. **INSERT into DELTA** with `INSERT_DATE` set to the upsert run timestamp. No truncation, the delta table is append-only.
8. **Log to CDC_RUN_LOG**.

### Step 3: Snapshot Refresh

1. **TRUNCATE** the SNAPSHOT table.
2. **INSERT** all rows from BASE into SNAPSHOT (soft-deleted rows included, they are still part of current state until housekeeping purges them).
3. SNAPSHOT is now identical to BASE, ready for the next day's comparison cycle.
4. **Log to CDC_RUN_LOG**.

### Housekeeping (Weekly, Independent Schedule)

1. **Purge CHANGE_HISTORY**: delete rows where `CHANGE_DATE` is older than `CHANGE_HISTORY_RETENTION_DAYS`.
2. **Purge DELTA**: delete rows where `INSERT_DATE` is older than `DELTA_RETENTION_DAYS`.
3. **Hard-delete soft-deleted BASE rows**: delete rows where `IS_DELETED = TRUE`, `DELETED_AT` is older than the grace period (e.g., 30 days), **and** a DELETE row for that key is present in DELTA with an `INSERT_DATE` on or after `DELETED_AT`. The delivery check means a failed or skipped delta run can never cause a delete to be purged before it was sent. The procedure refuses to run if the grace period is not shorter than delta retention, because the delivery evidence would otherwise have been purged from DELTA first.
4. **Log to CDC_RUN_LOG**.

---

## 5. Change Detection Mechanics

### RECORD_HASH

Every non-deleted row in the BASE table includes a `RECORD_HASH` column containing an MD5 hash of all non-key, non-timestamp columns concatenated with a pipe delimiter:

```
 RECORD_HASH = MD5(
 COALESCE(field1::VARCHAR, '') || '|' ||
 COALESCE(field2::VARCHAR, '') || '|' ||
 ...
 COALESCE(fieldN::VARCHAR, '')
 )
 ```

**Why MD5?** It's fast, deterministic, and sufficient for change detection (not used for security). The COALESCE ensures NULL values produce consistent hashes.

**What's included?** All business data columns. Excluded: primary key (doesn't change), system timestamps (created and updated timestamps, these are managed by the pattern itself), and the pattern's own `IS_DELETED` / `DELETED_AT` housekeeping columns.

### Field-Level Change Tracking

The CHANGE_HISTORY table stores changes in an **Entity-Attribute-Value (EAV)** format:

| Column | Description |
|---|---|
| `{PRIMARY_KEY}` | The primary key of the changed record |
| `CHANGE_DATE` | Timestamp of the CDC run that detected the change |
| `FIELD_NAME` | Name of the field that changed |
| `OLD_VALUE` | Previous value (cast to VARCHAR; NULL for INSERTs) |
| `NEW_VALUE` | New value (cast to VARCHAR; NULL for DELETEs) |
| `CHANGE_TYPE` | `INSERT`, `UPDATE`, or `DELETE` |

For an UPDATE that changes 3 fields on one record, 3 rows are written. For an INSERT, one row per field is written. For a DELETE, a single row with `FIELD_NAME = 'ALL_FIELDS'` is written.

---

## 6. Idempotency Contract

The upsert procedure includes a guard against duplicate processing:

```
 Before processing:
 IF EXISTS (SELECT 1 FROM CDC_RUN_LOG
 WHERE USE_CASE = '{use_case}'
 AND PROCEDURE_NAME = 'SP_{use_case}_UPSERT'
 AND RUN_TIMESTAMP::DATE = current_date
 AND STATUS = 'SUCCESS')
 THEN SKIP all processing
 RETURN 'Skipped, already processed for today'
 ```

This means:
- **Re-running the upsert** in the same day is safe, it will not double-count changes.
- **The MERGE is also skipped** on re-run, since BASE was already updated in the first execution.
- The delta procedure has its own guard: a second successful delta run for the same date is skipped, and it only reads CHANGE_HISTORY rows tied to the upsert's specific run timestamp.
- The snapshot procedure is naturally idempotent (truncate-and-reload).
- The housekeeping procedure is naturally idempotent (deletes based on age, not run state).

---

## 7. Delta Delivery Contract

The DELTA table is the **handoff point** between this CDC pattern and downstream integration:

- **Append-only**: rows are never updated or removed from the delta table. It serves as a persistent load history, bounded by retention.
- **Filtered by INSERT_DATE**: downstream systems query `WHERE INSERT_DATE >= :last_poll_timestamp` to retrieve new records.
- **ACTION-tagged**: every row carries `ACTION = 'UPSERT'` or `'DELETE'`, telling the downstream consumer exactly what to do with the row. There is no separate delete feed to reconcile against.
- **Full state rows, including deletes**: an upsert row contains the complete current state of the record. A delete row contains the complete *last-known* state of the record, since some downstream systems need the full context to locate and retire the record correctly, not just its key.
- **NULL coercion**: NULL values in VARCHAR columns are replaced with the literal string `'null'` for downstream compatibility. Numeric and timestamp NULLs are left as-is. This is a downstream integration constraint and should be understood by all consumers.
- **Backfill-friendly, within retention**: because delta is append-only, historical loads are preserved for the configured retention window. If a downstream job fails for N days (N less than the retention window), the delta table contains all those days' changes, filterable by INSERT_DATE.

---

## 8. Initial Load Process

When instantiating a new use case, the `SP_{USE_CASE}_INITIAL_LOAD` procedure handles first-time setup:

1. **Prerequisite, and the reason this pattern is rename-resilient**: the source view must exist and be **curated**, column names and types must match the expected downstream schema, accepted by consuming stakeholders. "Ready to consume" means the view is the agreed contract between source and target. Any future upstream rename or restructure is absorbed by redefining this view, not by touching the CDC objects.
2. **Populate BASE**: insert all rows from the source view with computed RECORD_HASH, `IS_DELETED = FALSE`.
3. **Populate SNAPSHOT**: copy all rows from BASE to SNAPSHOT (so the next day's comparison starts with a clean baseline).
4. **Seed DELTA**: insert all records into DELTA as the initial extract, `ACTION = 'UPSERT'`, with NULL coercion applied, for downstream to pick up.
5. **Log initial load** to CDC_RUN_LOG.

After initial load, the daily task graph and the independent housekeeping schedule take over.

---

## 9. Observability

### CDC_RUN_LOG Table

Stored in a dedicated `CDC_AUDIT` schema within the target database. Shared across all CDC use cases.

| Column | Type | Description |
|---|---|---|
| `RUN_ID` | `VARCHAR(36)` | UUID for each procedure execution |
| `USE_CASE` | `VARCHAR(256)` | Use case name |
| `PROCEDURE_NAME` | `VARCHAR(256)` | Which procedure ran |
| `RUN_TIMESTAMP` | `TIMESTAMP_TZ` | When the procedure started |
| `ROWS_INSERTED` | `INTEGER` | Count of new records |
| `ROWS_UPDATED` | `INTEGER` | Count of changed records |
| `ROWS_DELETED` | `INTEGER` | Count of removed records |
| `ROWS_DELTA` | `INTEGER` | Count of rows written to delta |
| `ROWS_PURGED` | `INTEGER` | Count of rows purged by housekeeping (NULL for non-housekeeping runs) |
| `STATUS` | `VARCHAR(10)` | `SUCCESS` or `FAILED` |
| `MESSAGE` | `VARCHAR` | Return message or error detail |

### What to Monitor

- **CDC_RUN_LOG where STATUS = 'FAILED'**: any procedure failures.
- **CDC_RUN_LOG where ROWS_INSERTED + ROWS_UPDATED + ROWS_DELETED = 0**: runs that detected no changes (normal, but worth watching for unexpected quiet periods).
- **DELTA table row counts by INSERT_DATE**: verify downstream is consuming data at the expected rate.
- **DELTA rows where ACTION = 'DELETE'**: unexpectedly high delete volume can indicate an upstream source issue rather than genuine record removal, worth a sanity check before it reaches downstream.
- **Task error notifications** via the configured notification integration.

---

## 10. Retention & Housekeeping

Retention is a first-class part of this pattern's design, not a deferred cleanup task. Every use case is instantiated with explicit retention windows (see Section 11), and the `SP_{USE_CASE}_HOUSEKEEPING` procedure runs on its own weekly schedule to enforce them.

### Change History

Purged past `CHANGE_HISTORY_RETENTION_DAYS` (default 365). This table is EAV-shaped, so it grows fastest on wide tables with frequent field-level changes, retention keeps it bounded.

### Delta Table

Purged past `DELTA_RETENTION_DAYS` (default 90). This window defines the practical backfill capacity: if a downstream consumer is down longer than this window, a re-run of initial load (or a manual gap-fill) is required rather than relying on delta history.

### Base Table (Soft-Deleted Rows)

Soft-deleted rows are hard-purged from BASE after a grace period (default 30 days), and only once a DELETE row for them is confirmed in DELTA. The grace period must be shorter than delta retention.

**What actually bounds a downstream outage is delta retention, not the grace period.** A delivered DELETE row stays in DELTA for the full delta retention window whether or not its BASE row has been purged, so a consumer that is down for less than delta retention still receives it. Purging BASE only changes what happens if the same key reappears later: it arrives as a fresh INSERT. This keeps BASE from growing indefinitely with deleted records while still allowing a short window for investigation or manual recovery.

### CDC_RUN_LOG

Low volume (a handful of rows per day per use case, plus one weekly housekeeping row). No retention concern anticipated.

---

## 11. Inputs Required to Instantiate a New Use Case

To create a new CDC feed using this pattern, you need:

| Input | Description | Example |
|---|---|---|
| **Source view** | Fully qualified name of a curated, stakeholder-accepted view. Columns must match the expected downstream output schema. | `DB.SCHEMA.V_MY_USE_CASE` |
| **Use case name** | Short identifier used in all object names. Uppercase, underscores. | `CUSTOMER_PROFILE` |
| **Primary key column** | The column that uniquely identifies each record. | `CUSTOMER_ID` |
| **Target database** | Where all CDC objects will be created. | `MY_INTEGRATION_DB` |
| **Target schema** | Schema within the target database for this use case's objects. | `MY_DATA_SCHEMA` |
| **Warehouse** | Compute warehouse for task execution. | `COMPUTE_WH` |
| **Daily cron schedule** | Schedule for the root task (subsequent daily steps follow automatically via task graph). | `0 5 * * *` (daily at 05:00) |
| **Housekeeping cron schedule** | Schedule for the independent housekeeping task. | `0 6 * * 0` (weekly, Sunday 06:00) |
| **Change history retention (days)** | How long field-level change audit rows are kept. | `365` |
| **Delta retention (days)** | How long delivered delta rows are kept, defines backfill window. | `90` |
| **Soft-delete grace period (days)** | How long a deleted record's last-known state is kept in BASE after removal is delivered downstream. | `30` |
| **Timezone** | Timezone for cron and timestamp operations. | `Australia/Sydney` |
| **Notification integration** | (Optional) Snowflake notification integration for task error alerts. | `MY_NOTIFICATION_INT` |

---

## 12. Naming Conventions

All objects follow this pattern:

```
 Tables: {USE_CASE}_BASE
 {USE_CASE}_SNAPSHOT
 {USE_CASE}_CHANGE_HISTORY
 {USE_CASE}_DELTA

Procedures: SP_{USE_CASE}_INITIAL_LOAD
 SP_{USE_CASE}_UPSERT
 SP_{USE_CASE}_DELTA
 SP_{USE_CASE}_SNAPSHOT
 SP_{USE_CASE}_HOUSEKEEPING

Tasks: TSK_{USE_CASE}_CDC (daily root, carries daily cron)
 TSK_{USE_CASE}_UPSERT (predecessor: root)
 TSK_{USE_CASE}_DELTA (predecessor: upsert)
 TSK_{USE_CASE}_SNAPSHOT (predecessor: delta)
 TSK_{USE_CASE}_HOUSEKEEPING (independent root, carries weekly cron)

Audit: CDC_AUDIT.CDC_RUN_LOG (shared table in dedicated schema)
```

---

## 13. Scope Limits (v1)

- **Single-column primary key only.** Composite keys change the join, hash and EAV key columns throughout; they are a known limitation, not a hidden assumption. Concatenating a composite key into one surrogate column in the source view is the supported workaround.
- **Daily batch.** One upsert per use case per day is the unit of idempotency. Intra-day runs need a different guard.
- **The source view is a prerequisite, not an output.** The pattern assumes a curated, stakeholder-accepted view already exists.

---

## 14. Why Snapshot Compare, Not Streams or Dynamic Tables

Snowflake has native options for change data. This pattern is for the cases where they do not fit, and it says so rather than competing with them.

**Streams** record row-level DML on a table (or on a view, with change tracking enabled on its underlying tables). They are the right choice when the source is a table that is updated incrementally. They are a weaker fit when the source is a curated view over batch-refreshed data: an upstream truncate-and-reload is still DML, so it can surface as churn rather than real business change, and a stream records that a row changed, not which fields changed or what they used to be. This pattern compares values, so a reload that changes nothing produces nothing, and every real change is recorded per field with its old and new value.

**Dynamic Tables** keep a transformed result current. They answer "what does the data look like now", not "what changed since the consumer last polled", so on their own they do not give a downstream reverse ETL job an append-only, date-filtered delta with deletes in it.

**Where this pattern does not apply:** sources with trustworthy native change tracking (use Streams), near-real-time requirements (use Streams with tasks, or Dynamic Tables with a short target lag), and consumers that only need to know a row changed rather than how (a MERGE on RECORD_HASH is enough).

