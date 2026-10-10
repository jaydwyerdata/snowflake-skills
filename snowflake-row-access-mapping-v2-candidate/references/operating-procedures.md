# Operating Procedures, V2

Standard procedures for administrators running a V2 row access mapping instance. Object names below
are placeholders (`<GOVERNANCE>` for the private governance schema, `SP_ONBOARD_ACCESS_V2` and so on
for the procedures); the instance's own build record has the real names and says which version of
the implementation was verified.

The v1 worked examples implement simpler whole-file rejection and do not implement everything below.
Do not assume an instance meets this contract until it has been tested against it.

---

## Before you operate

Every procedure here is run by the access-admin role, with secondary roles off, by an accountable
person:

```sql
USE ROLE <ACCESS_ADMIN_ROLE>;
USE SECONDARY ROLES NONE;
```

Before changing anything, confirm the session is what you think it is: the real primary role, any
session restrictions, the current procedure and policy definitions, the tracker state, the grants and
the refresh state. Preserve audit evidence throughout.

Two teams, two jobs. The source-owning team maintains the source data. The access-admin team operates
the governed copy. Giving consuming users or service accounts their roles, and giving them warehouse
access, are separate steps done through whoever owns those grants.

---

## The request file

Every bulk change starts with a CSV prepared by an analyst.

- **Mode A:** key and role.
- **Mode B:** the business identifiers, the key, and optionally the role.
- **Derived roles:** analysts leave the role out, and the role name is built from the configured
  naming convention.

For a composite assignment, one row covers a whole group:

```
PRODUCT_ID,SUPPLIER_ID,MAPPING_KEY
1001,2001,GROUP_A
```

Every row in the data with that product and supplier receives the assignment, including rows that
arrive later. The internal refresh ID is never a CSV column.

Rules for the file:

- A header row, then the exact columns in the exact order, with keys in the agreed case.
- Blank identifiers with a key is a deliberate key-only grant, and it is only valid if that key
  already has assigned records. A row with some identifiers blank and some filled is invalid.
- Offboarding uses key and role.
- Validate both the file path and the content. Under manual onboarding, uploading a file grants
  nothing on its own; the onboarding call does. If uploads ever trigger onboarding automatically,
  the right to upload becomes the right to grant access, so treat it that way.

Upload the file to the request stage in Snowsight (the stage's **+ Files** button).

---

## SOP 1: Submit a request file and review the result

1. Upload the approved file.
2. Run the onboarding procedure for that exact file:
   ```sql
   CALL <GOVERNANCE>.SP_ONBOARD_ACCESS_V2('<file>.csv');
   ```
   Naming one file processes that file only; it does not process everything on the stage. An
   implementation that processes all files must enumerate file versions and check its durable
   manifest. Either way, filename and content identity, and every submission, are kept.
3. Review the durable results, not just the returned message. Inspect the VARIANT status the call
   returns, then the request, run, mapping and assignment rows:

| Status | What it means | What to do |
|---|---|---|
| PASS | Applied successfully. A matching pair on its own is not enough. | Nothing. |
| PENDING | Not in the governed snapshot yet. That is not proof the record is outside the group. | If it is unexpected, check source filters and freshness. If a recheck trigger was agreed, it is rechecked on every onboarding call, so calling onboarding again later (even with the same file, whose rows come back SKIPPED) picks up records that have since arrived. |
| REJECTED | Invalid, or a conflict. | Fix it and submit a new file or version. The original reason and payload are kept. |
| SKIPPED | A duplicate of an existing logical request. | Nothing. Some older implementations only return a count and store no SKIPPED rows, so do not expect a stored status there. |
| FAILED | Application did not complete. | Inspect grants, mappings, assignments and the tracker independently. Do not retry by replaying all historical PASS requests. |

**The re-run test.** Running an identical file again must not duplicate rejected history, change
newer assignments or restore access that was explicitly revoked. If it does any of those, stop
production onboarding and fix the lifecycle design before going further.

---

## SOP 2: Offboard access

1. Remove the approved key and role mapping through the audited procedure, single or bulk:
   ```sql
   CALL <GOVERNANCE>.SP_OFFBOARD_ACCESS_V2('<key>', FALSE);
   ```
2. Offboarding cancels or supersedes any pending work for that mapping, and stops old submissions
   from recreating it. Assignment data and request history are kept.
3. If the role now maps to nothing, it is kept with `SELECT` revoked, or dropped, according to the
   chosen setting.
4. Bringing access back later needs an explicit new authorisation (SOP 3). Resubmitting an old file
   does not.

**Check it the right way.** After the last mapping is removed and `SELECT` is revoked, the viewer
should get an access-control error. Zero rows is the expected result only when `SELECT` remains but
the role has no matching mapping. Record an actual `SELECT` run as the viewer, with its primary role,
secondary-role setting and error. An admin query showing zero mappings is not an access-denial test.

---

## SOP 3: Reauthorise a key

```sql
CALL <GOVERNANCE>.SP_REAUTHORIZE_ACCESS_V2('<key>', '<reason, at least 10 characters>');
```

Reauthorisation is an explicit, audited operation with a reason. Renaming and resubmitting an old
CSV is not reauthorisation.

---

## SOP 4: Refresh the governed copy

The refresh reads the source, refuses an empty or ambiguous snapshot, merges source fields,
soft-deletes rows that have gone and restores rows that come back. In composite Mode B, assignments
are stored durably at the business grain so that new child rows inherit them. If an implementation
lacks that relation, document the gap.

Check the actual schedule in the task's metadata. A periodic cron is not a guarantee that the refresh
runs straight after the source changes. A stream design on a dynamic table needs an incremental
refresh and committed stream consumption. Keep tasks suspended until acceptance, and do not resume
them as part of validation unless that was agreed. Do not call the refresh helper directly; use the
lifecycle procedure or its wrappers.

---

## SOP 5: Troubleshoot a privilege error

- Find the exact failing statement in the stored procedure body, and check the current grants. Line
  numbers reported from a procedure body do not line up with worksheet lines.
- Granting database `USAGE` to others needs grant authority. Reading the source stage and creating a
  file format in a schema you own are separate privileges.
- Warehouse `USAGE` does not give you the right to grant that warehouse to anyone.
- Do not fix any of these with broad `MANAGE GRANTS`.
- When the current user's name is used as an identifier, quote it first, because names often contain
  periods or `@`:
  ```sql
  SET ME = (SELECT '"' || REPLACE(CURRENT_USER(), '"', '""') || '"');
  ```
  then use `IDENTIFIER($ME)`.
- Querying staged files with `FILE_FORMAT =>` needs a named file format. Filter to the exact file.

---

## SOP 6: Recover from an interrupted run

A run that is interrupted leaves its single-writer token committed. Later calls fail busy until the
run is reconciled. That is deliberate: it stops a second writer acting on half-finished state. Do not
delete the token.

1. **Use a separate recovery session** that never runs the writer `CALL` itself. If the writer needs
   to be started for a drill, start it in a separate process with a unique query tag.
2. **Abort only the writer.** Abort the mutex's `OWNER_SESSION`, after confirming it is not
   `CURRENT_SESSION()`.
3. **Wait for evidence, not acknowledgement.** The `SYSTEM$ABORT_SESSION` response does not mean the
   writer has finished. Recheck the exact parent `CALL`. In testing, a `CALL` could still show
   `RUNNING` with an epoch END_TIME after its session was reported gone; if so, cancel that query ID
   only.
4. **Unlock only on the exact token.** Before unlocking, require a terminal history row for the
   `CALL`, the captured token, session and acquire time unchanged, and no reachable open transaction.
5. **Reconcile request by request.** Mark unfinished attempts FAILED and eligible for retry, keep
   committed PASS and applied work as it is, then clear only the captured token.
6. **Retry once.** Allow one operator retry after the unlock.

QA helpers written to classify one-request test fixtures are not production unlock procedures.

---

## SOP 7: Verify and keep the evidence

- Test on synthetic fixtures in a dedicated schema. Never clean up real data as part of testing.
- Save results to a durable table with a run identity and the code version tested.
- Disable secondary roles for viewer tests. A parent role that inherits an exemption sees all rows,
  so it is not a substitute for a viewer role.
- If session restrictions stop you assuming a role, record that test as NOT TESTED and hand that
  exact test to a session that is allowed to run it.
- Do not rebuild historical baselines after the fact, and do not treat a successful compile as a
  passing runtime test.
- Opening a new worksheet can lose session variables. `GETVARIABLE` with a literal name is a safe way
  to detect a missing value, but prefer durable tables for new runs.
- Clean up only the exact artefacts the test created, after the results are saved. Keep audit and
  tracker history. Never delete audit rows by loose text matching, never clear an entire group's
  assignments, and never expect the audit count to be zero. Do not rerun a `CREATE OR REPLACE`
  installation or destructive deltas to get evidence back.
