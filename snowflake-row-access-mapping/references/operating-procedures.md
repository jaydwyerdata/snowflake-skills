# Operating Procedures

Standard procedures for administrators running a row access mapping instance. Names below follow
the worked examples (`RAP_KEYED` for Mode A, `RAP_DEMO` for Mode B, `SERVICE_TICKETS`,
`REGION_CODE`); substitute your own. Where Mode B differs, it says so.

All procedures are run by the admin role, with secondary roles off, by an accountable person. Every
action is recorded in `GOVERNANCE.ACCESS_AUDIT`; every rejected row in `GOVERNANCE.ACCESS_REJECTIONS`.

```sql
USE ROLE RAP_DEMO_ADMIN;
USE SECONDARY ROLES NONE;
```

Data flows: the data team's table, then `SP_REFRESH_FROM_SOURCE()` (scheduled, or on demand), then
the governed copy that consumers query. Access flows: CSV, then the onboarding procedure, then the
mapping table. They are independent; a rebuild upstream never changes who has access.

---

## The request file

Every bulk change uses a CSV prepared by an analyst.

Mode A (key already in the data):
```
MAPPING_KEY,ROLE_NAME
NORTH,RAP_DEMO_NORTH_TEAM
EAST,RAP_DEMO_SOUTH_TEAM
```

Mode B (the business assigns the key): a third column in front, `RECORD_ID`:
```
RECORD_ID,MAPPING_KEY,ROLE_NAME
T-1001,NORTH,RAP_DEMO_NORTH_TEAM
,EAST,RAP_DEMO_SOUTH_TEAM
```
A blank `RECORD_ID` grants the role a key that already has records without assigning any.

- A header row, then exactly the columns above.
- Keys and role names exactly as they must appear: the file is validated as written, not tidied.
- One file is one request. If any row fails validation, the whole file is rejected and nothing is
  applied. Fix the file and resubmit it under a new name.
- Offboarding uses a two-column file (`MAPPING_KEY,ROLE_NAME`) in both modes.

Upload it to the `GOVERNANCE.ACCESS_REQUESTS` stage (Snowsight: the stage's **+ Files** button, or
`PUT file://... @RAP_DEMO.GOVERNANCE.ACCESS_REQUESTS`).

---

## SOP 1: Give a new group access to its slice

*A new team, partner or division needs to see the rows for one or more keys.*

1. Confirm the role name follows the naming convention and the keys exist in the data.
2. Prepare and upload the request file, one row per key.
3. Run:
   ```sql
   CALL RAP_DEMO.GOVERNANCE.SP_ONBOARD_ACCESS('<file name>');
   ```
4. Expect `Onboarded N mappings, created 1 roles from <file>` (Mode B: `Assigned N records, onboarded N mappings, created N roles from <file>`). The role is created, granted read
   access to the table, and granted to `SYSADMIN`.
5. Hand over to your own user onboarding: grant the role to the consuming users or service account,
   and give it a warehouse. This pattern deliberately does not do that step.
6. Verify (SOP 7).

## SOP 2: Extend an existing group to another key

*An existing role should also see another division or region.*

Same as SOP 1, with a file containing only the new key and the existing role name. Expect
`created 0 roles`. Existing mappings are untouched; re-submitting one that already exists is a no-op.

## SOP 3: Share one key with a second group

*Two roles both need the same slice.*

Same as SOP 1: a file mapping the key to the second role. Both roles see the slice; removing either
mapping later does not affect the other.

## SOP 4: Remove one mapping

*A role should stop seeing one key, effective immediately.*

```sql
CALL RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS('<key>', '<role>', FALSE);
```

Access ends on the next query, including open BI reports on refresh. If that was the role's last
mapping, its read grant on the table is revoked; the role itself is kept.

## SOP 5: Remove a group entirely

*A team or partner is leaving and their role should go.*

Single mapping:
```sql
CALL RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS('<key>', '<role>', TRUE);
```

Several mappings at once: upload a request file listing each (key, role) to remove, then
```sql
CALL RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS_FILE('<file name>', TRUE);
```

With `TRUE`, a role left with no mappings is dropped, which also removes it from every user who held
it. The data itself is not deleted: without a mapping it is simply invisible. Deleting rows is the
data pipeline's decision, not an access change.

## SOP 6: A request file was rejected

*The procedure returned `Rejected <file>: N of M rows failed validation, nothing applied`.*

1. Find out why:
   ```sql
   SELECT FILE_ROW, MAPPING_KEY, ROLE_NAME, REASON
   FROM RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
   WHERE SOURCE_FILE = '<file name>'
   ORDER BY FILE_ROW;
   ```
2. Typical reasons and fixes:
   | Reason | Usual cause |
   |---|---|
   | Mapping key breaks the key format | Lowercase, spaces, or a different separator |
   | Mapping key not found in the data | A typo, or no live row has that key yet (Mode A) |
   | Record ID not found in the data | Mode B: a typo, or the record has not arrived or was soft-deleted |
   | Record listed with more than one key | Mode B: the same record under two keys in one file |
   | Key granted without records, but no record has that key | Mode B: a blank record ID for a key nobody has been assigned |
   | Role name breaks the naming convention | Lowercase, missing prefix or suffix, or stray characters |
   | No such mapping to remove | Offboarding a mapping that was never granted, or already removed |
   | More than two (or three) columns | An extra column or a stray delimiter |
   | File has no data rows | Header only, or the wrong file |
3. Correct the file, upload it under a new name, and run the procedure again. Nothing from the
   rejected file was applied, so there is nothing to undo.

## SOP 7: Check who can see what

All mappings, newest first:
```sql
SELECT MAPPING_KEY, ROLE_NAME, GRANTED_AT, GRANTED_BY, SOURCE_FILE
FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING
ORDER BY GRANTED_AT DESC;
```

Keys that nobody can see (often intentional, sometimes a gap):
```sql
SELECT DISTINCT d.REGION_CODE
FROM RAP_DEMO.SHARED.SERVICE_TICKETS d        -- run as the admin role, or the policy hides rows
WHERE d.REMOVED_AT IS NULL AND NOT EXISTS (SELECT 1 FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING m WHERE m.MAPPING_KEY = d.REGION_CODE);
```

See exactly what one role sees, through its own eyes:
```sql
USE ROLE <role>;
USE SECONDARY ROLES NONE;     -- essential: otherwise your other roles leak into the result
SELECT REGION_CODE, COUNT(*) FROM RAP_DEMO.SHARED.SERVICE_TICKETS GROUP BY 1;
USE ROLE RAP_DEMO_ADMIN;
```

## SOP 8: Review recent activity

```sql
SELECT EVENT_AT, ACTION, MAPPING_KEY, ROLE_NAME, ACTOR, DETAIL
FROM RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
WHERE EVENT_AT >= DATEADD(day, -30, CURRENT_TIMESTAMP())
ORDER BY EVENT_AT DESC;
```

Worth a periodic look: `FILE_REJECTED` counts (repeated rejections suggest the analyst guidance
needs updating) and `GRANT` volume against what was expected.

## SOP 9: Change a validation rule

*The key format or role naming convention needs to change.*

```sql
UPDATE RAP_DEMO.GOVERNANCE.ACCESS_CONFIG SET VALUE = '<new regex>' WHERE SETTING = 'KEY_PATTERN';   -- or ROLE_PATTERN
```

Test the new pattern first against the existing mappings, since anything that no longer matches can
no longer be offboarded by name until it is renamed:

```sql
SELECT * FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING WHERE NOT REGEXP_LIKE(ROLE_NAME, '<new regex>');
```

---

## SOP 10: Refresh the governed copy

*The data team has loaded or rebuilt their table.*

Scheduled: the refresh task runs after their load. To run it now, for an urgent change:
```sql
EXECUTE TASK RAP_DEMO.GOVERNANCE.TSK_REFRESH_SERVICE_TICKETS;
-- or directly:
CALL RAP_DEMO.GOVERNANCE.SP_REFRESH_FROM_SOURCE();
```
Expect `Refreshed: N new, N changed, N removed, N restored`.

- `Refused: source is empty, governed copy left unchanged`: the data team's table is empty, usually
  a rebuild in progress. Nothing was changed. Run again once their load completes.
- Removed rows are soft-deleted: hidden from consumers, kept with their key. If they return, they
  are restored with their assignment. Soft-deleted rows can be listed as the admin role:
  ```sql
  SELECT * FROM RAP_DEMO.SHARED.SERVICE_TICKETS WHERE REMOVED_AT IS NOT NULL;
  ```
- Mode B: new rows stay invisible until a request assigns them (SOP 1). Mode A: new rows are
  visible as soon as their key is mapped.
- A refresh never adds, changes or removes a mapping. Only offboarding removes mappings.

To start or pause the schedule: `ALTER TASK RAP_DEMO.GOVERNANCE.TSK_REFRESH_SERVICE_TICKETS RESUME;`
(or `SUSPEND`). The task is created suspended.

## SOP 11: The data team is about to rebuild their table

Nothing needs doing for access. The governed copy, its policy and its grants are not part of their
table. After their rebuild, run SOP 10. If they change the record ID scheme, stop and talk first:
the refresh cannot tell a changed row from a new one without a stable ID.

---

## What these procedures never do

- Assign roles to users, grant warehouses, or manage authentication. That is your own onboarding.
- Delete rows from the governed copy. Removing a mapping is what removes access, and the refresh
  only ever soft-deletes.
- Write to the data team's table.
- Accept part of a file. A request is applied completely or not at all.
