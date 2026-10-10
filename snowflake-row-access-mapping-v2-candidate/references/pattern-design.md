# Row Access Mapping Pattern, V2

## 0. The Core Idea

V2 keeps the v1 idea unchanged: access is data, not DDL. Consumers query one governed table, a row
access policy on it checks a governed mapping table, and granting or removing access is a row change
made by an audited procedure.

What V2 adds is honesty about what happened to every request. An analyst's CSV can name records that
are not in the data yet, the same file can be submitted twice, someone can be offboarded while their
request is still waiting, and a run can be interrupted halfway. V2 is built so that each of those
cases ends in a clear, recorded state, and so that nothing quietly gives access back after it has
been removed.

Four properties carry it:

- **PASS means applied.** A request is only PASS once the assignment, mapping and grants are actually
  in place. A matching pair on its own is not success.
- **Assignments live at the business grain.** An analyst assigns a group (for example a product and
  supplier pair), and every row in that group, including rows that arrive later, inherits it.
- **One writer at a time.** Onboarding, offboarding, reauthorisation and refresh all take the same
  lock, and a second caller is told the system is busy rather than taking over.
- **Offboarding wins.** Once access is removed, no replayed file, pending request or recheck can
  bring it back. Only an explicit reauthorisation can.

The v1 worked examples predate all of this. Their whole-file validation and tests show the basic
pattern works; they are not evidence that V2 is correct.

---

## 1. When to Use V2

- The CSV may list records that are not in the data yet, and those requests should wait rather
  than be rejected.
- Access is assigned to a group that is broader than one physical row, and new rows in that group
  should inherit it.
- More than one person or schedule may run onboarding, offboarding or refresh.
- You need to show what happened to every request, not just whether a file loaded.

### When v1 is enough

- Every row in the CSV is already in the data, and access is assigned one record at a time.
- One administrator runs everything by hand, and whole-file rejection is acceptable.

---

## 2. Modes and Assignment Grain

**Mode A** copies the source's own key onto the governed copy on every refresh. **Mode B** stores
assignments made by the business, independently of anything in the source. Do not choose Mode A just
because nobody is sure; ask who owns the key.

In Mode B the assignment grain can be composite and broader than a physical row. If an analyst
assigns a product and supplier pair, every row that shares those identifiers gets the same key.
Analysts work with readable identifiers, so never expose an internal hash as something they have to
type.

Roles can be derived rather than typed. When they are, the CSV has no role column and the role name
is built from a configurable pattern, `<PREFIX>_<KEY>_<SUFFIX>`, and validated before any dynamic
SQL uses it.

Use generic names such as "source-owning team" and "access-admin team" in reusable documents; an
instance's own build record uses the user's real terminology.

---

## 3. Identity and Refresh

The source is read-only. Its owning team can rebuild it whenever they like without touching the
governed copy, its policy, its assignments or its grants. After a rebuild, still check that the
access team's source privileges and the schema are compatible.

### Checking row identity

Check identity with a `GROUP BY` over the actual identifying columns and explicit `NULL` checks. Do
not count concatenated strings, because a delimiter inside a value can make two different rows look
the same. `SELECT DISTINCT` removes exact duplicate rows only; it does nothing about two different
rows that claim the same key. And do not blame an upstream join for duplicates just because
duplicates or multiple parents exist; say so only with evidence.

Use a stable ID from the source where one exists. If you have to build a deterministic hash instead,
serialise the inputs unambiguously: `NULL` must hash differently from an empty string, and no value
should be able to imitate a delimiter. If any hash input can be edited upstream, an edit creates a
new identity; document that. Never generate a UUID inside the refresh, because a new random value on
every run means every row looks new every time.

### The refresh

The refresh takes a snapshot of the source before it starts its DML transaction. It refuses an empty
source, and it refuses keys that would make the `MERGE` ambiguous. Then it updates changed source
fields, inserts new rows, soft-deletes rows that have gone and restores rows that come back. Source
data types are preserved unless a conversion is deliberate.

In Mode B the refresh must never overwrite an assignment decision. For composite-grain assignments it
reads a durable assignment relation, so that a new row for an already assigned pair picks up its key
straight away rather than sitting unassigned and invisible.

### Scheduling and streams

Confirm how the source is actually refreshed before proposing streams. If it is a dynamic table,
check its refresh mode: a stream design needs an incremental source with supported change tracking,
and the stream only advances when committed DML consumes it. `SYSTEM$STREAM_HAS_DATA` on its own does
not consume anything. A FULL-refresh dynamic table cannot support this design.

A cron or polling task is not guaranteed to run straight after each source refresh, so do not
describe it as "after refresh". Create the task suspended, keep it suspended until the build is
validated, and never change a user's schedule without their say-so.

---

## 4. Objects and the Access Boundary

| Where | What lives there |
|---|---|
| Shared schema | The governed copy, with its key, stable row ID and refresh and removal metadata. |
| Private governance schema | Access mappings, the assignment relation, lifecycle requests, submissions and load history, audit, config, the request stage, named CSV formats, owner's-rights procedures and the task. |
| Admin role | Owns governance and the viewer roles it creates; holds `SELECT` on the source and `CREATE ROLE`. |
| Auditor role (optional) | Read access, with a policy exemption. |
| Viewer roles | `USAGE` on the shared database and schema and `SELECT` on the governed copy. Nothing on governance or the source. |

### The policy

The policy checks `IS_ROLE_IN_SESSION`, not equality with `CURRENT_ROLE`. Give its key argument a name
that differs from every mapping-table column; if they match, the correlated comparison can quietly
become a column compared with itself, which is always true.

The admin role must be exempt, otherwise its own `MERGE` and `UPDATE` statements cannot see the rows
they need to change. Exemptions follow role inheritance: if the admin or auditor role is granted to a
parent role, that parent sees every row, including unassigned and removed ones. A parent that only
inherits viewer roles sees mapped live rows. `USE SECONDARY ROLES NONE` does not remove what the
primary role inherits, so record every inheritance path.

### Grants

- `USAGE` on a database does not let you grant `USAGE` to others. Use the narrowest grant option
  that works, or have the owner issue the grant.
- Warehouse access is a separate concern. Do not put warehouse `GRANT` statements in an owner's-rights
  procedure unless the owner has confirmed it has that authority.
- Never reach for `MANAGE GRANTS` as a workaround.
- Internal stages use `READ`, and `WRITE` only where needed, not `USAGE`.
- Create named file formats in a schema you own, not in the source team's schema.
- Read the exact approved filename, not every file on the stage.

### Granting to the current user

When the current user's name is used as an identifier, quote it first, because names often contain
periods or `@`:

```sql
SET ME = (SELECT '"' || REPLACE(CURRENT_USER(), '"', '""') || '"');
```

Then use `IDENTIFIER($ME)`, not `IDENTIFIER(ME)`. The `SELECT` wrapper matters: it is what lets a
`SET` take an expression.

---

## 5. The Request Lifecycle

V2 separates two things. A **submission** is one row as it was seen in one file. A **request** is the
logical ask behind it, which may be submitted more than once. Keeping them apart is what lets a
retry be recorded without creating a second request.

A robust tracker keeps, for each submission and request: request and run IDs, filename, file content
or version identity, file row, the parsed identifiers, key and role, the raw input or raw fields,
who submitted it and when, when it was last checked, the state of any application attempt, who
resolved it and when, and links to any duplicate or superseded requests. Every submission keeps its
own provenance.

### Statuses

| Status | Meaning |
|---|---|
| PASS | The assignment and authorisation were applied successfully. A matched pair alone is not PASS. |
| PENDING | Valid, but not in the governed snapshot yet. This does not prove the record is not a member of the group; a filter, stale data or another source condition can explain it. |
| REJECTED | Invalid format, or a conflict that is not allowed. Fixing it takes a new version or submission. |
| SKIPPED | A duplicate submission. Say whether it is stored in submission history or only counted: a count in a return value is not a tracker row. |
| FAILED, CANCELLED, SUPERSEDED | Application failures and cancellations by offboarding need their own explicit states, or a separate application-state relation. Never record them as a falsely successful PASS. |

### Rules for requests

- Deduplicate within a file and against history using null-safe keys, so an identical retry does
  not duplicate rejected rows.
- Reject more than one key for the same pair, unless an explicit, ordered reassignment workflow
  exists.
- A key-only request (blank identifiers) must refer to a key that already has assignments. It is a
  deliberate new authorisation, not a way of reopening old requests.
- If agreed, every onboarding call rechecks pending requests from earlier files. This is what makes
  PENDING useful: calling onboarding again, at any time and even with the same file, picks up
  records that have since arrived in the source. The file's own rows come back SKIPPED as
  duplicates; it is the recheck of the existing PENDING requests that moves them to PASS.
- Each call works only on its own actionable set, identified by run and request IDs. Never pick out
  old PASS rows by filename plus `MIN(SUBMITTED_AT)`.
- Submitting a completed file again must not restore access that offboarding removed. Offboarding
  cancels or supersedes any unresolved work for that key and role, and later rechecks must not bring
  it back. Reinstating access needs a new, explicit approval.

### Files

Calling a procedure with one file parameter (`P_FILE`) processes that file only; it does not
enumerate the stage. Processing every new file needs a manifest of file versions and explicit
enumeration. Validate filenames before they reach dynamic SQL, constrain paths, escape where needed
and bind values wherever binding is supported. Validate every derived identifier too.

### Repairing an older tracker

A tracker built before V2 can be repaired in a scoped way. Snapshot the rows newly classified as PASS,
and the matching PENDING rows, before updating statuses, rather than querying historical PASS rows
afterwards. Use null-safe joins to history, including blank key-only requests. Exclude pending
requests that predate a retained key and role `REVOKE` event.

This is not full cancellation. Audit retention becomes security-critical, offboarding a key that only
had pending work may emit no revoke at all, and concurrent changes still need serialising. Test it
with identical and renamed files, blank identifiers, roles kept and dropped, unrelated pending
resolutions and new assignments. Do not use a replay of historical PASS rows as retry recovery;
add explicit application states instead.

When only a procedure is being replaced, keep its grants with `COPY GRANTS` (placed before `RETURNS`)
and keep its original owner role. Never rerun a full installation to deploy a patch like this.

---

## 6. Transactions and Retries

Some steps cannot be rolled back. A temporary `CREATE TABLE` is DDL and commits implicitly, and
`CREATE ROLE` and grants are not part of a DML rollback. So the order is:

1. Stage and classify the input, and provision the role and grant prerequisites, before the DML
   transaction starts.
2. Then commit the assignment, mapping, status and audit changes together, atomically, as far as
   possible.
3. Audit the provisioned prerequisites and any failures, so that a recovery run is idempotent.

Do not infer that a role was created from the audit history. `CREATE ROLE IF NOT EXISTS` succeeding
only means the role exists now, so report roles as "ensured" unless an actual creation was observed.
Serialise all changes, or implement concurrency control and test it.

Partial application can happen in older builds: an assignment, tracker row or role can exist without
its mapping after a grant fails. Inspect each piece of state explicitly. Never repair it by replaying
every PASS row.

---

## 7. Offboarding

Remove the mapping straight away. When a role has no mappings left, either keep it and revoke
`SELECT`, or drop it, according to the agreed setting. Keep the data and the assignment history.

The two outcomes test different things. After the last mapping is removed and `SELECT` is revoked,
the viewer should get an authorisation error. A role that keeps `SELECT` but has no mapping should
see zero rows. Test both.

Validate offboarding inputs as carefully as onboarding inputs. A bulk rejection must still be
logged, and the log must not reference tables that have been removed.

---

## 8. Verification, Migration and Retention

### Testing

Check which role is actually executing before any DDL runs. Test on isolated synthetic fixtures with
copies of the deployed procedures and policy, and record any namespace substitutions. This proves the
behaviour, but not production owner-grant authority if the fixture owner is different.

Never test with a broader role and call it viewer isolation. If the session will not let you switch
to the viewer role, the test is NOT TESTED; do not work around the restriction.

Save test observations before any cleanup: run identity, code version, expected and actual result,
status, time, and query or error IDs. Cover pending resolution, assignment grain, malformed and
duplicate input, conflicts, role isolation, soft deletion, revocation, replay after offboarding,
cancellation, new child rows, failure recovery and concurrency. A procedure compiling is not a
runtime test.

Historical baselines that were never captured cannot be rebuilt from today's counts. Call
`GETVARIABLE` with a literal, uppercase name (in testing it did not accept a computed name); to look
up a variable dynamically, build an object of literal `GETVARIABLE` calls and `GET` from it. Session variables do not survive across worksheet files.
Report PASS, FAIL and NOT TESTED separately, and never weaken a failing check to make it pass.

### Migration and cleanup

Use additive migrations. Never replace a populated tracker table or drop history for convenience.
Keep audit evidence through test cleanup.

Cleanup touches only the objects and rows the test run owns, plus the prior assignment values it
needs to restore. Never use group-wide updates or loose matches on audit `DETAIL` text, and never
treat an audit count of zero as a sign of correctness. In a real-data build, avoid blanket schema
or role teardown.

---

## 9. The Release Gate

Do not call the V2 design production-ready if any of these is true:

- a replayed file can undo a revocation;
- PASS can be recorded before the change is applied;
- pending work survives offboarding without being cancelled;
- conflicting requests are ambiguous;
- new members of an assigned group do not inherit the approved assignment.

Document any of these as a blocker, not as a feature.

---

## 10. Hardening Lessons

These are lessons from hardening the V2 design. The worked example in `examples/composite_grain/`
exercises the lifecycle, assignment and offboarding lessons; the single-writer and interrupted-session
lessons are not yet tested there.

### The single writer

- Use a committed, non-expiring single-writer token that spans both the prerequisite DDL and the
  atomic application transaction. Onboarding, offboarding, reauthorisation and refresh must all take
  it. A second caller fails busy; it never steals the lease automatically. An interrupted run needs
  deliberate reconciliation before the token is released.
- Use a durable blocked flag and an authorisation generation for every key, including keys that only
  have pending work. Reauthorisation is an explicit, audited operation, not a renamed CSV. Commit
  generation changes together with the approval request.

### Requests and application

- Persist requests and every parsed submission separately. Content-version and row provenance, plus
  a deterministic logical request identity, let an identical retry keep its observations without
  creating duplicate requests. Parser failures need an explicit raw-line or quarantine design; a
  FAILED run is not the same as tracking every row.
- Provision role and grant prerequisites first, then commit assignments, mappings, PASS and audit
  together. Prove rollback and retry by injecting a failure before `COMMIT`, not just by creating the
  procedure successfully.
- The refresh must apply durable business-grain assignments to new child records. Keep older hash or
  type behaviour only on purpose, with guards and a separate migration plan.

### Validation

- Exact CSV column-count checks must handle empty extra fields and the header row. Strict basename
  validation stops a stage path being smuggled in as input. Configurable role names need length
  checks too.

### Testing

- Real concurrency tests need server-side `ASYNC` child jobs and `AWAIT` when the client runs calls
  one at a time.
  `SYSTEM$WAIT` returns text such as `waited 10 seconds`, so store it in a `VARCHAR`. Do not assume
  the case of a boolean cast to text; check the actual value your test compares against.
- Build fresh synthetic schemas for each complete regression run, and keep old harness FAILs with an
  explanation. A client test whose calls never overlap is not concurrency coverage. Attach the real
  policy in QA.
- Install candidates side by side before activating them, and do not mix older mutators with the new
  locked paths. Inspect each candidate's VARIANT status: a `CALL` can succeed while the application
  inside it returns FAILED.
- Additive migrations must refuse populated-state imports they do not support, rather than silently
  dropping or reinterpreting history. Keep the original entry points, task state and definitions
  until acceptance.
- Recovery tests must tell apart a committed-token interruption, partial grants, caught exceptions,
  a lost response after commit, and a failed offboarding DDL. Check what the viewer can actually see
  when `SELECT` is left behind, not just the mapping counts. Keep fault injections as evidence in the
  code, but remove any that still execute.
- Test-only namespace substitution must cover standalone schema `GRANT` identifiers as well as dotted
  table names. Check the actual role grants before viewer testing, and revoke anything unintended
  straight away.

### From the first worked example runs

Each of these broke the procedures or the test on a first run, and each fix is in the example.

- **Procedure arguments in SQL need a colon.** Snowflake Scripting binds a variable into a SQL
  statement only with a `:` prefix; without it, the name is read as a column. Offboarding failed with
  "invalid identifier 'P_KEY'". Checks outside SQL (`IF`, `RETURN`, assignments) do not need it,
  which is why the key-format check passed and the first SQL statement failed.
- **Never read a generated key back with `MAX()`.** Since the 2024_01 behaviour change, new
  AUTOINCREMENT columns and sequences default to NOORDER, so the highest ID is not necessarily the row
  just inserted. Reading the run ID with `MAX(RUN_ID)` logged two runs under one ID and marked the
  wrong run complete. Take the ID from a sequence created with `ORDER` before the insert, and use it.
- **A missing file reads as zero rows, not an error.** Querying a stage path with no file behind it
  returned nothing, so a mistyped filename completed with every count at zero (observed in testing).
  Treat zero rows read as a failed run.
- **Keep `UPDATE` subqueries simple.** An `UPDATE` whose `WHERE` used `IN` against a subquery with
  `QUALIFY ROW_NUMBER()` failed with "Unsupported subquery type cannot be evaluated" (observed in
  testing). Finding the first row of each group with `GROUP BY` and `MIN()` instead worked. The other
  checks use non-correlated `IN` lookups on joined keys, which also worked.
- **Secondary roles hide missing grants.** A Snowsight session starts with secondary roles on, so an
  administrator's roles quietly supplied a warehouse the viewer role did not have. With secondary roles
  off, the viewer could not use the warehouse until it was granted. Warehouse access is consumer
  onboarding, granted by the warehouse owner, not the access-admin role.
- **Unloading test CSVs with empty fields needs an enclosing character.** `COPY INTO` a stage refuses
  to write an empty string unless `FIELD_OPTIONALLY_ENCLOSED_BY` is set, because without quotes an
  empty string cannot be told apart from NULL.

### Interrupted sessions

Snowflake documents that `SYSTEM$ABORT_SESSION` terminates a session, but not how quickly the queries
in it stop. The points below are observed behaviour from testing, not documented guarantees, which is
why the design never relies on them: it fails busy and waits for evidence instead.

- A synchronous early return after a committed boundary simulates a stuck state; it does not test a
  real session being terminated. A production unlock needs independent evidence that the writer has
  finished, an exact-token compare-and-update, request-by-request reconciliation and a transactional
  recovery audit. Never assume a writer is dead because its timestamp is old, and never reset PASS
  work that has already committed to FAILED.
- In testing, aborting a session behaved asynchronously: the "terminated" response arrived before the
  parent `CALL` had been cleaned up. Recheck the exact query ID. `RUNNING` with an epoch END_TIME does not prove the
  work is live, but it does not prove it has finished either. If the writer session is gone and the
  `CALL` still has no real END_TIME, cancel that query ID. Cancelled statements show up as error text
  such as `SQL execution canceled`, not only in EXECUTION_STATUS.
- Keep the recovery session separate from the writer. A client timeout in the same session can leave
  the token owned by the recovery session, and then aborting `CURRENT_SESSION()` hits the operator,
  not the writer. A later writer must still fail busy rather than steal that token.
- Query history and `SHOW TRANSACTIONS` or `SHOW LOCKS` in the current user's scope can be empty while
  a leftover `CALL` is still settling. Seeing other users' transactions and locks with `IN ACCOUNT`
  requires the ACCOUNTADMIN role, which the access-admin role should not have. No visible locks is
  not enough evidence to unlock on its own.

---

References: Snowflake documentation on transactions, GET_DDL, row access policies, Snowflake Scripting
variables, CREATE SEQUENCE (the 2024_01 NOORDER default) and COPY INTO location.
