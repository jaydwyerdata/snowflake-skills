# Row Access Mapping Pattern

## 0. The Core Idea

Access is data, not DDL. Consumers query one governed table. A row access policy on it checks one
governed mapping table that says which roles may see which mapping keys. Granting or removing
access is a row change made by an audited procedure, and it takes effect on the very next query,
including live BI connections such as Power BI DirectQuery, without touching the table, the policy
or any consumer's query.

Default deny is the property that makes it safe: a role with `SELECT` on the table but no mapping
sees zero rows.

---

## 1. When to Use It

- One table must be shared with several groups, each of which may only see its own slice.
- The slice is decided by a key (division, region, partner, client).
- The set of groups changes over time, and onboarding should be a repeatable, audited step rather
  than hand-written grants.
- The table is owned by a different team that may rebuild it at any time.

### When not to

- Each group needs different columns hidden, not different rows: use masking policies.
- Visibility depends on the person rather than a role: use `CURRENT_USER()` in the mapping instead.
- The groups are separate Snowflake accounts that can receive a share: consider Secure Data Sharing
  with a listing filtered per consumer account.

---

## 2. Two Modes

**Mode A, the key is already in the data (the common case).** The data team populates the key on
every row. The CSV has two columns, `MAPPING_KEY, ROLE_NAME`, and only decides which role sees which
key. The governed copy carries the key from the source on every refresh, so a key changed upstream
is followed automatically, and a new row with an already-mapped key is visible after the next refresh
with no CSV at all.

**Mode B, the business assigns the key.** The rows arrive with no key. The CSV has three columns,
`RECORD_ID, MAPPING_KEY, ROLE_NAME`: it assigns each listed record its key and maps the key to a
role. A blank `RECORD_ID` grants a role a key that already has records. The key is owned by the
governed copy and the refresh never touches it, so new rows arrive unassigned and invisible until
a CSV assigns them.

Everything else is identical: policy, soft delete, refresh, offboarding, audit, validation.

Solution diagrams: [Mode A](../examples/keyed_column/solution-diagram.png) and
[Mode B](../examples/service_tickets/solution-diagram.png).

---

## 3. Why There Is a Governed Copy

A row access policy and its grants belong to the table object. If the owning team runs
`CREATE OR REPLACE TABLE`, the policy and every grant are dropped, and the table is exposed to
whoever can reach it. In Mode B the assignments would be wiped as well.

So consumers never query the other team's table. The access team owns a governed copy in its own
schema, with the policy attached, and refreshes it from the source with a MERGE on a stable record
ID. A rebuild of the source cannot touch the copy, its policy or its grants. The source is only
ever read; the pattern changes nothing in the other team's table.

The record ID must be stable: the same record keeps the same ID across rebuilds. If it is not,
resolve that first; the refresh cannot tell a changed row from a new one without it.

If the access team owns the table outright and nobody else can replace it, the copy can be skipped
and the policy attached directly. The default is to keep it.

### Choosing the record ID

The refresh can only match a row to the copy if its ID is unique and does not change. Check first:

```sql
SELECT COUNT(*) AS rows, COUNT(DISTINCT <id or id columns>) AS distinct_ids,
       COUNT_IF(<id> IS NULL) AS null_ids
FROM <source>;
```

Rows must equal distinct IDs, with no NULLs. Then, in order:

1. **One column that passes.** Use it.
2. **A composite that passes** (for example a timestamp and a name). Build a deterministic surrogate in
   the refresh, such as a hash of the columns joined with a delimiter and explicit NULL handling, and
   use it as the record ID. It is only as stable as its columns: if any of them can be corrected
   upstream, the record will look new and lose its assignment. Mode A tolerates this best, because
   analysts never handle the ID. Mode B does not, because the CSV lists it and a hash is unreadable.
3. **Duplicates, NULLs, editable columns, or any doubt.** Recommend that the data team assigns a
   unique ID once, when a record is first loaded (a UUID is fine), and never changes it. This is the
   only case where a UUID helps, and it must come from the source, not from the refresh.

Never generate a random ID in the refresh. The ID exists to recognise the same record next time, and a
fresh random value is by definition different next time: every refresh would look like all new rows
and every assignment would be lost.

### The refresh

`SP_REFRESH_FROM_SOURCE()` runs as the admin role:

- **Refuses an empty source**, so a half-built rebuild cannot blank the copy. The refusal is audited.
- **New rows** are inserted (Mode B: unassigned; Mode A: with the source's key).
- **Changed rows** are updated (Mode A includes the key; Mode B never touches the key).
- **Rows missing from the source are soft-deleted**: `REMOVED_AT` is stamped, the row and its key
  stay, and the policy hides it from every consumer.
- **Returning rows are restored**: `REMOVED_AT` is cleared and the assignment is intact, with no CSV.
- The result is audited and returned as `Refreshed: N new, N changed, N removed, N restored`.

A scheduled task calls it after the data team's load. It is created suspended and can always be run
on demand with `EXECUTE TASK` when a change is urgent. Real-time freshness is not the goal; a streaming
alternative is covered in section 10.

---

## 4. Object Inventory

| Object | Purpose |
|---|---|
| `<SOURCE>.<TABLE>` | The data team's table. Only ever read. |
| `<SHARED>.<TABLE>` | The governed copy consumers query. Policy attached. Carries `REFRESHED_AT` and `REMOVED_AT` (and, in Mode B, the key column). |
| `GOVERNANCE.ACCESS_MAPPING` | One row per (mapping key, role). Many-to-many. The security boundary. |
| `GOVERNANCE.ACCESS_AUDIT` | Every grant, revoke, assignment (Mode B), role creation and drop, refresh and rejected file. |
| `GOVERNANCE.ACCESS_REJECTIONS` | One row per failing CSV row: file, row number, values, reason, actor, time. |
| `GOVERNANCE.ACCESS_CONFIG` | Validation rules: `KEY_PATTERN` and `ROLE_PATTERN` regular expressions. |
| `GOVERNANCE.<POLICY>` | The row access policy over (key, `REMOVED_AT`). |
| `GOVERNANCE.ACCESS_REQUESTS` | Internal stage for onboarding CSVs. |
| `GOVERNANCE.FF_ACCESS_CSV` | CSV file format with a header row. |
| `GOVERNANCE.SP_REFRESH_FROM_SOURCE()` | Merges the source into the governed copy. |
| `GOVERNANCE.TSK_REFRESH_<TABLE>` | Scheduled refresh; suspended until the user is ready. |
| `GOVERNANCE.SP_ONBOARD_ACCESS(file)` | Validates and applies one CSV. Owner's rights. |
| `GOVERNANCE.SP_OFFBOARD_ACCESS(key, role, drop)` | Removes one mapping; tidies up the role if unused. |
| `GOVERNANCE.SP_OFFBOARD_ACCESS_FILE(file, drop)` | Bulk removal from a two-column CSV. |
| Admin role | Owns all of the above; holds `CREATE ROLE` on the account and owns every viewer role it creates. |

Consumer roles get `USAGE` on the shared database and schema and `SELECT` on the governed copy only.
They never get `USAGE` on the governance or source schemas.

---

## 5. The Policy

```sql
CREATE ROW ACCESS POLICY GOVERNANCE.RAP_<TABLE>
AS (KEY_VALUE VARCHAR, REMOVED TIMESTAMP_TZ) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('<ADMIN_ROLE>')
  OR IS_ROLE_IN_SESSION('<EXEMPT_ROLE>')          -- optional
  OR (REMOVED IS NULL AND EXISTS (
    SELECT 1 FROM GOVERNANCE.ACCESS_MAPPING m
    WHERE m.MAPPING_KEY = KEY_VALUE
      AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
  ));
```

attached with `ALTER TABLE ... ADD ROW ACCESS POLICY ... ON (<key column>, REMOVED_AT)`.

**`IS_ROLE_IN_SESSION`, not `CURRENT_ROLE()`.** It respects role inheritance and secondary roles,
which is how users actually work. The consequence is section 6.

**Name the argument something no mapping-table column is called.** If it were called `MAPPING_KEY`,
then inside the subquery the name would resolve to the mapping table's own column, the comparison
would be true for every mapping row, and every mapped role would see every row. Nothing errors;
row-level security silently stops working. The easiest way to get this pattern wrong.

**The admin role is exempt on purpose.** A row access policy filters not only SELECT but also UPDATE
and MERGE: a role that cannot see a row cannot change it. Without the exemption, the refresh and
the onboarding procedures could not touch rows they are meant to maintain.

---

## 6. Role Hierarchy: the Decision to Make Deliberately

Because the policy checks `IS_ROLE_IN_SESSION`, any user who inherits a viewer role sees that
role's rows. The pattern follows standard Snowflake practice and grants every viewer role to
`SYSADMIN`, so administrators can manage them. Consequence, tested in the worked examples: anyone
using `SYSADMIN` or `ACCOUNTADMIN` sees every mapped row (never an unmapped one, never a soft-deleted
one). That is usually acceptable, since those roles can alter the policy anyway, but it should be a
decision, not a surprise.

The stricter variant, where even administrators see nothing unless explicitly mapped: keep viewer
roles standalone (owned by the admin role, since ownership does not confer inheritance, and granted
only to their consumers), and give administrators an explicit exempt role when they need to see
everything, so that access is visible and auditable.

Always test with `USE SECONDARY ROLES NONE`, or the tester's other roles make the policy look more
permissive than it is.

---

## 7. Onboarding Flow

1. An analyst prepares a CSV with a header: `MAPPING_KEY, ROLE_NAME` (Mode A) or
   `RECORD_ID, MAPPING_KEY, ROLE_NAME` (Mode B).
2. They upload it to the `ACCESS_REQUESTS` stage.
3. An accountable person runs `CALL GOVERNANCE.SP_ONBOARD_ACCESS('<file name>')`.
4. The procedure validates the whole file before changing anything. A row fails if it has extra
   columns, a key breaking `KEY_PATTERN`, a role breaking `ROLE_PATTERN` (role names reach dynamic
   SQL, so this is also the injection guard), or a key no live row uses (almost always a typo).
   Mode B also fails a record ID that does not exist, and a record listed under two different keys.
   The file is read exactly as written, so a lowercase key is caught, not silently fixed.
5. If any row fails, the whole file is rejected: each failing row and its reason go to
   `ACCESS_REJECTIONS`, one `FILE_REJECTED` entry goes to `ACCESS_AUDIT`, and nothing is applied, not
   even the valid rows.
6. Otherwise, in one transaction: Mode B assigns the listed records their keys; then for each
   distinct (key, role) the role is created if absent, granted `USAGE` on the shared database and
   schema and `SELECT` on the governed copy, granted to `SYSADMIN` (section 6), and the mapping is
   added if new. Every step is audited.
7. It returns a one-line summary.

Re-running the same file changes nothing. Assigning the roles to users, warehouse access and
authentication are the consumer's own onboarding and out of scope.

## 8. Offboarding Flow

`CALL GOVERNANCE.SP_OFFBOARD_ACCESS('<key>', '<role>', <drop_role_if_unused>)` deletes the mapping,
which removes access on the next query. If the role now maps to nothing, it is dropped, or kept with
its `SELECT` revoked, depending on the flag. Both are audited.

`SP_OFFBOARD_ACCESS_FILE('<file>', <drop>)` takes a two-column CSV, validates it the same way
(also rejecting any mapping that does not exist), and removes each mapping through the single
procedure, so bulk and single behave identically.

Offboarding never deletes data and never clears assignments. Without a mapping the rows are
invisible. Mappings are removed only by offboarding, never by a refresh or a rebuild upstream.

---

## 9. The Security Boundary

- **The mapping table.** Anyone who can write to it can grant themselves rows. Only the admin role
  can, and only through the procedures in normal operation.
- **The governed copy.** Anyone who can write to it can change what consumers see. Admin role only.
- **The onboarding stage.** Under the default, on-demand model, writing a file grants nothing until
  an accountable person runs the procedure.
- **Dynamic SQL.** Every role name is validated before it reaches `CREATE ROLE` or `GRANT`.
- **The admin role** holds `CREATE ROLE`, not `MANAGE GRANTS`.
- **The source table** is never written to, and consumers have no access to it.

---

## 10. Evolving Towards Automation

The default is deliberate: access changes are infrequent and security-sensitive, so a person runs
the procedure and the audit log records who. The procedures are safe to re-run, which is the
prerequisite for automating them.

- **Scheduled onboarding.** A task periodically calls the procedure for files not yet processed
  (tracked in a processed-files log).
- **Stream on a directory table, with a triggered task.** Enable a directory table on the stage, put
  a stream on it, and run a task only `WHEN SYSTEM$STREAM_HAS_DATA`. Snowpipe does not fit: it loads
  data, it cannot create roles or grant access.
- **Fresher data.** A task on a tighter schedule, or a stream on the source table (only works while
  the source object is never replaced), triggers the refresh. Dynamic Tables are not a fit for the
  copy: it needs a MERGE that keeps its own columns and soft deletes.

Automating onboarding moves the security boundary: write access to the stage becomes, in effect, the
power to grant data access, so the stage needs the same lockdown as the mapping table, and an approval
step is worth considering.

---

## 11. Known Limits

- One mapping key column per table, holding one value per row. A multi-valued column (for example a
  comma-separated tag list) needs splitting into a bridge table, which is not supported here.
  Multi-dimensional rules need a composite key.
- One protected table per instance. Protecting several tables with the same mapping means one governed
  copy and policy per table, sharing the mapping, and extending the onboarding grants.
- The key check rejects keys with no live row; onboarding access ahead of data arriving needs that
  check relaxed or replaced with a reference list of valid keys.
- The refresh is a periodic snapshot, not real time.
- Large tables: the refresh compares every row. For very large tables, key the comparison on a hash
  or a change timestamp.
