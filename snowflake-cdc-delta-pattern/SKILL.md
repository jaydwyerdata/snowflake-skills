---
name: snowflake-cdc-delta-pattern
description: Generate a complete Snowflake snapshot-based Change Data Capture (CDC) pipeline that produces a delta table for a downstream reverse ETL or integration consumer. Use this whenever the user needs to detect and deliver incremental changes (inserts, updates, and deletes) from a curated Snowflake source view to a downstream system that polls for changes, especially when the source has no native CDC and the user needs field-level change auditing, not just row-level change flags. Trigger this for requests like "build a CDC feed for X", "I need a delta table for reverse ETL", "detect changes for a downstream sync", or "set up change tracking for this view", even if the user does not use the words "CDC" or "snapshot" explicitly.
---

# Snowflake Snapshot CDC Delta Pattern

Generates a full snapshot-based CDC pipeline (tables, procedures, tasks) for a single use case, on top of a curated Snowflake source view, producing an append-only delta table that a downstream reverse ETL or integration job can poll. Finishes by writing a build record (see Step 5).

## When to use this pattern

Use it when all of these are true:

- The source is a batch-refreshed Snowflake view or table with no native change tracking (no Streams, no reliable trustworthy timestamp column).
- A downstream consumer needs a flat, appendable table of changed records, filtered by date, not direct query access to the source.
- Field-level audit (what changed, old value, new value) matters, not just "this row changed."
- Daily-batch cadence is acceptable. This is not built for sub-minute change detection.

Do not use it when the source has native CDC (Streams), or when changes are high-frequency. Say so and suggest Streams or Dynamic Tables instead.

## The core design principle, state this to the user

This pattern is deliberately naive about upstream renames. It does not try to track column lineage or handle schema drift inside the CDC engine. Instead, it relies on the source view being the enforced contract: renames, restructuring, and curation logic happen once, at the view layer, before anything reaches the CDC objects. The destination is assumed to be a system where column names are fixed. That is what makes this pattern durable against upstream schema change without special-case logic. When explaining or documenting this pattern, always lead with this, it is the pattern's actual value, not an implementation detail.

## Full reference

`references/pattern-design.md` contains the complete pattern specification: architecture diagram, object inventory, data flow for every step (upsert, delta extraction, snapshot refresh, housekeeping), change detection mechanics, idempotency contract, delta delivery contract, and retention design. Read it in full before generating SQL. Do not improvise steps that contradict it.

## Instantiation workflow

### Step 1: Gather inputs

Before generating anything, confirm every input in this table with the user. Do not guess values, especially the primary key and retention windows, ask if not given.

| Input | Required | Notes |
|---|---|---|
| Source view (fully qualified) | Yes | Must already be curated and stakeholder-accepted. If it does not exist yet, that is a separate prerequisite task, do not proceed until it exists. |
| Use case name | Yes | Uppercase, underscores, becomes the `{USE_CASE}` token in every object name. |
| Primary key column | Yes | Single column only in v1. If the natural key is composite, stop and ask the user to expose one surrogate key column in the source view; do not generate composite-key SQL. |
| Target database and schema | Yes | Never hard-code a Snowflake organization or account identifier anywhere in generated SQL, use context (`CURRENT_DATABASE()`, session context, or explicit user-supplied names) instead. |
| Warehouse | Yes | |
| Daily cron schedule and timezone | Yes | Drives the root daily task. |
| Housekeeping cron schedule | Yes | Independent of the daily chain, weekly is a reasonable default, confirm with user. |
| Change history retention (days) | Yes | Default suggestion: 365. Confirm, do not silently assume. |
| Delta retention (days) | Yes | Default suggestion: 90. This is also the practical backfill window, explain that tradeoff to the user. |
| Soft-delete grace period (days) | Yes | Default suggestion: 30. |
| Notification integration | No | Optional, only include error-notification logic if the user has one. |

### Step 2: Confirm the delete-handling approach

Deletes are delivered through the same DELTA table as inserts and updates, tagged `ACTION = 'DELETE'`, carrying the record's last-known field values rather than an empty row. This is a deliberate design choice, not an oversight, confirm the downstream consumer can handle an ACTION column, or ask the user how their downstream system expects deletions signaled if not.

### Step 3: Generate the object set

Using the naming convention and full object inventory from `references/pattern-design.md`, generate, in order:

1. `{USE_CASE}_BASE`, `{USE_CASE}_SNAPSHOT`, `{USE_CASE}_CHANGE_HISTORY`, `{USE_CASE}_DELTA` table DDL, including `RECORD_HASH`, `IS_DELETED`, `DELETED_AT` on BASE, and `ACTION` on DELTA.
2. `CDC_AUDIT.CDC_RUN_LOG` DDL, only if it does not already exist for this target database, ask the user rather than assuming.
3. `SP_{USE_CASE}_INITIAL_LOAD` procedure.
4. `SP_{USE_CASE}_UPSERT` procedure, including the idempotency guard and soft-delete logic, with every write inside one transaction.
5. `SP_{USE_CASE}_DELTA` procedure, including its own once-per-day idempotency guard, ACTION tagging and NULL coercion.
6. `SP_{USE_CASE}_SNAPSHOT` procedure.
7. `SP_{USE_CASE}_HOUSEKEEPING` procedure, using the retention values gathered in Step 1. It must only hard-purge a soft-deleted BASE row once a DELETE row for that key is confirmed in DELTA, and must refuse to run if the grace period is not shorter than delta retention.
8. The daily task graph (`TSK_{USE_CASE}_CDC` root plus UPSERT, DELTA, SNAPSHOT as chained predecessors) and the independent `TSK_{USE_CASE}_HOUSEKEEPING` task.

`examples/customer_profile/02_objects.sql` is a complete, live-tested instance of this object set; follow its structure. Write actual runnable SQL, not pseudocode, using the field list from the source view provided by the user. If the user has not supplied the source view's column list, ask for it, `RECORD_HASH` and NULL-coercion logic both require the full field list to be correct.

### Step 4: Explain before handing off

After generating the SQL, give the user a short summary covering:

- Where the view-as-contract boundary sits, and what that means for future upstream renames.
- How a delete flows end to end (soft-delete in BASE, logged to CHANGE_HISTORY, delivered to DELTA with `ACTION = 'DELETE'` and last-known values, eventually hard-purged from BASE by housekeeping).
- The retention windows chosen and what they mean practically (delta retention equals the maximum backfill gap before a manual re-load is needed).

### Step 5: Write the build record

Always finish by writing `BUILD_RECORD.md` in the user's project, following
`references/build-record-template.md`: what was built, every input and decision and why, the source
contract, every object and its owner, how a change flows through, the delivery contract for the
consumer, how it was verified and what was not, and a handover checklist. Use the real names from
this build. Append a dated section if the file exists. Offer it to the user before ending.

## Guardrails

- Never hard-code a Snowflake organization or account identifier in generated SQL or documentation. Use database/schema names the user supplies, or session context functions.
- Never silently assume retention values, primary key structure, or delete-handling expectations. Ask.
- If the user's source view is not yet curated or stakeholder-accepted, flag this as a blocking prerequisite before generating the initial load procedure, the whole pattern depends on that view being the stable contract.
- If asked to adapt this for native CDC (Streams available), say so plainly and recommend Streams-based CDC instead of forcing this pattern.

## Reference files

- `references/pattern-design.md`: full pattern specification (architecture, all four+one procedures in detail, retention design, observability, scope limits, and why not Streams or Dynamic Tables). Read before generating any SQL.
- `references/build-record-template.md`: the build record to write at the end.
- `examples/customer_profile/solution-diagram.png`: the solution diagram for the worked example.
- `examples/customer_profile/`: a worked example (setup, object set, a five-day walkthrough and 19 PASS/FAIL assertions), run live in a Snowflake trial account on 7 October 2026.
