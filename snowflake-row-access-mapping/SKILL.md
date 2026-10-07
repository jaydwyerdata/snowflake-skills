---
name: snowflake-row-access-mapping
description: Generate a Snowflake row-level security pattern where a mapping table decides which roles can see which rows of a shared table, enforced by a row access policy, with audited procedures to onboard and offboard access from an analyst's CSV, plus a governed copy that survives the source table being rebuilt. Use this when the user needs to share one table with several groups who must each see only their own slice (by division, region, partner, client or similar), whether the consumers are internal teams, BI tools such as Power BI or Tableau over a live connection, or external parties. Trigger for requests like "each team should only see their own rows", "row-level security for this table", "share this table but filter by division", or "set up a row access policy with a mapping table", even if the user does not name row access policies.
---

# Snowflake Row Access Mapping Pattern

Generates a mapping-table row access pattern for one shared table: a governed copy of the table that
consumers query, the mapping table, the row access policy, an onboarding stage and file format,
audited onboarding and offboarding procedures driven by an analyst's CSV, a scheduled refresh from
the source table, and an audit log. Finishes by writing a build record (see the last step).

## The core design principle, state this to the user

Access is data, not DDL. Who can see which rows lives in one governed mapping table, so granting or
removing access is a row change, applied by an audited procedure, and takes effect immediately on
every query, including live BI connections. Default deny: a role with `SELECT` on the table but no
mapping sees zero rows.

## Two modes. Decide which one first

| | Mode A (the common case) | Mode B |
|---|---|---|
| The key (division, region, partner) | Already populated on every row by the data team | Not on the rows; the business decides which record belongs to which group |
| The CSV | Two columns: `MAPPING_KEY, ROLE_NAME` | Three columns: `RECORD_ID, MAPPING_KEY, ROLE_NAME` (blank `RECORD_ID` grants a role an existing key) |
| What the CSV does | Says which role may see which key | Also assigns each listed record its key |
| Governed copy | Carries the key from the source on every refresh, so upstream key changes are followed | The key is owned here; the refresh never touches it. New rows arrive unassigned and invisible |
| Worked example | `examples/keyed_column/` | `examples/service_tickets/` |

Ask "who populates the key?". If the user is unsure, it is Mode A.

## Full reference

`references/pattern-design.md` holds the full specification: object inventory, the policy and why it
is written the way it is, the governed copy and soft delete, both modes, onboarding and offboarding
flows, the security boundary, automation options and known limits. Read it in full before
generating SQL. Follow the structure of the matching worked example; both are live-tested.

## Instantiation workflow

### Step 1: Agree the design decisions

Confirm every item with the user before generating anything. Do not guess; ask.

| Decision | Notes |
|---|---|
| Mode | A or B, as above. |
| Source table (fully qualified) | The table the data team owns. It must already exist. The skill only ever reads it. |
| Record ID column | Needed in both modes: a stable, unique ID, so the same record keeps the same ID across rebuilds. The refresh merges on it. Check, never assume: count duplicates and NULLs (for a composite, group by the whole combination) and show the user the result. Then follow the ladder in `references/pattern-design.md` section 3: a single column that passes is used as is; a composite that passes becomes a deterministic hash surrogate, with the caveat that it is only as stable as its columns; anything else, or any doubt, means recommending that the data team assigns a unique ID once, when a record is first loaded (a UUID is fine), and never changes it. Never generate a random ID inside the refresh. In Mode B the CSV lists this ID, so it must be readable by analysts; a hash is not. |
| Mapping key column | Mode A: the existing column. Mode B: the name for the new key column on the governed copy. Confirm what happens to rows where it is NULL (default: visible to nobody but the exempt roles). The column must hold exactly one value per row. A column that can hold a list (comma-separated tags, for example) cannot be used as it is: ask for a single-valued column. A bridge table of (record ID, key) rows is not supported in this version. |
| Key cardinality | Each row has one key. One role seeing many keys, and one key shared by several roles, are both supported; ask which the user expects so the walkthrough tests it. |
| Mapping key format | For example capitals separated by underscores, or numeric only. Becomes `KEY_PATTERN` in `ACCESS_CONFIG`; a CSV row breaking it rejects the whole file. |
| Role naming convention | For example `DIVISION_<KEY>_ROLE`. Becomes `ROLE_PATTERN`, so a badly named role is rejected rather than created. |
| Admin role | Owns the governed copy, governance schema, policy and procedures. It needs `CREATE ROLE` on the account, not `MANAGE GRANTS`. It is exempt from the policy (a row access policy also filters UPDATE and MERGE, so without the exemption the refresh could not run). |
| Role hierarchy | Default: grant each viewer role to `SYSADMIN`. State the consequence: because the policy uses `IS_ROLE_IN_SESSION`, anyone using `SYSADMIN` or `ACCOUNTADMIN` inherits every viewer role and sees all mapped rows. Confirm, or offer the stricter variant in the reference. |
| Exempt (audit) role | Optional role that sees every row. Default: none. |
| Offboarding default | When a role maps to nothing: drop it, or keep it and revoke its read grant. |
| Refresh schedule | Cron for the refresh task, after the data team's load. Default the timezone to `Australia/Sydney`, not UTC, written as `USING CRON <cron> Australia/Sydney`; confirm the time and timezone with the user, and note that it follows daylight saving. It can always be run on demand. Created suspended until the user is ready. |
| Who owns the table | If the user owns the table outright and nobody can `CREATE OR REPLACE` it, the governed copy can be skipped and the policy attached directly. Say so and confirm; the default is to keep the copy. |
| Database and schema names | Use names the user supplies. Never hard-code an organisation or account identifier. |

### Step 2: Confirm what is out of scope

Assigning roles to users, warehouse access, and how consumers authenticate are the user's own
onboarding process. Say so. Do not build user management.

### Step 3: Generate the object set

In this order, following the matching `02_objects.sql`:

1. A `SHARED` schema for the governed copy and a `GOVERNANCE` schema for everything else, owned by
   the admin role. Consumer roles never get `USAGE` on `GOVERNANCE`.
2. The governed copy: the source's columns, the key column (Mode B only), `REFRESHED_AT`, and
   `REMOVED_AT` for soft delete.
3. `ACCESS_MAPPING`, `ACCESS_AUDIT`, `ACCESS_REJECTIONS`, `ACCESS_CONFIG` (`KEY_PATTERN`, `ROLE_PATTERN`).
4. The row access policy over (key, `REMOVED_AT`): exempt roles pass; everyone else needs
   `REMOVED_AT IS NULL` and a mapping row for a role in session (`IS_ROLE_IN_SESSION`). Name the
   argument something no mapping column is called.
5. `SP_REFRESH_FROM_SOURCE()`: refuse an empty source; MERGE on the record ID; new rows in; changed
   rows updated; rows gone from the source soft-deleted (stamped, key kept); returning rows restored.
   Mode A also merges the key. Mode B never touches the key.
6. A refresh task, created suspended, runnable on demand with `EXECUTE TASK`.
7. File format and stage for requests.
8. `SP_ONBOARD_ACCESS(file)`: validate the whole file first, reject it whole and log every failing
   row if any rule breaks; otherwise create the role, grant read on the governed copy only, grant to
   `SYSADMIN` if agreed, add the mapping, audit. Mode B also assigns the listed records.
9. `SP_OFFBOARD_ACCESS(key, role, drop_role_if_unused)` and `SP_OFFBOARD_ACCESS_FILE(file, drop)`.

Offboarding never deletes data: removing the mapping removes access.

Write runnable SQL, not pseudocode.

### Step 4: Generate the walkthrough and assertions

Adapt `03_walkthrough.sql` and `04_assertions.sql` to the user's table and roles, so they can prove
the pattern in their own account before relying on it. Every role check must run with
`USE SECONDARY ROLES NONE`. The teardown must reclaim ownership before dropping, because the admin
role owns the database, warehouse and roles.

### Step 5: Explain before handing off

Point the user to `references/operating-procedures.md`, adapted to their names. Summarise: where the
security boundary is (the mapping table, the governed copy and the onboarding stage), what a
consumer's own onboarding still has to do, the role hierarchy decision, and how refresh and
offboarding behave.

### Step 6: Write the build record

Always finish by writing `BUILD_RECORD.md` in the user's project, following
`references/build-record-template.md`: what was built, every decision and why, every object and its
owner, how it was verified and what was not, and a handover checklist. Use the real names from this
build. Append a dated section if the file exists. Offer it to the user before ending.

## Guardrails

- Never hard-code an organisation or account identifier.
- Never generate a record ID inside the refresh with a random function such as `UUID_STRING()`: nothing ties a row to the ID it had last time, so every refresh would look like all new rows and every assignment would be lost.
- Never modify the source table; only read it.
- Never accept a multi-valued key column or an unverified record ID. Run the checks and show the results.
- Never give consumer roles `USAGE` on the governance schema or write access to the mapping table.
- Never build role names into dynamic SQL without validating them against the agreed convention.
- Never grant `MANAGE GRANTS` to the admin role; ownership of the roles it creates is enough.
- Never physically delete rows from the governed copy in the refresh; soft delete only.
- If the user asks for automatic onboarding when files land, explain that write access to the stage
  then becomes the power to grant access, and follow the automation notes in the reference.

## Reference files

- `references/pattern-design.md`: full specification. Read before generating SQL.
- `references/operating-procedures.md`: administrator SOPs for each scenario. Adapt and hand over.
- `references/build-record-template.md`: the build record to write at the end.
- `examples/keyed_column/`: Mode A worked example (setup, objects, walkthrough, PASS/FAIL assertions).
- `examples/service_tickets/`: Mode B worked example, with its verified run.
