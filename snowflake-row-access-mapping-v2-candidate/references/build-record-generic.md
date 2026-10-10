# Build Record: Row Access Mapping Pattern (generic companion)

This is the organisation-neutral companion to an instance `BUILD_RECORD.md`. Every value in angle
brackets is a placeholder to fill from what was actually built. Do not copy historical example
results or reconstruct missing evidence.

**Date:** `<date>` **Built by:** `<person>` **Instance:** `<database>`, Mode `<A or B>`
**Verified implementation:** `<legacy tracker / V2 candidate / not promoted>`

## Summary

A row access mapping pattern was built for `<source description>`. Analysts assign
`<assignment grain>` through CSV. Consumers see only mapped live rows. The source stays read-only. A
governed copy holds policy, assignments and grants.

## Decisions made

| Decision | Choice | Why | Alternative rejected |
|---|---|---|---|
| Mode | `<A or B>` | `<why>` | `<alternative>` |
| Source | `<DB>.<SCHEMA>.<TABLE>` read-only | Exact existing object | Inferring Mode A from uncertainty |
| Source-owning / access-admin teams | `<user terminology>` | Source owner vs governance operator | Generic labels that hide ownership |
| Assignment grain | `<e.g. product + supplier>` | Analyst grain, not physical-row grain | One CSV row per physical row |
| Durable pair assignment | `<yes/no>` | New child rows inherit approved pairs | Assign only rows present at onboard time |
| Record identity | `<stable id or documented hash inputs>` | Whole-column uniqueness checked | Random refresh IDs |
| Deduplication | `<exact-row DISTINCT or none>` | Observed exact duplicates only | Claiming an unproven join fan-out |
| Mapping key / role | `<PREFIX>_<KEY>_<SUFFIX>` | Derived roles if agreed | Analyst-supplied unsafe identifiers |
| Admin / auditor | `<roles>` | CREATE ROLE, optional exemption | Broad MANAGE GRANTS |
| Inheritance | `<parents of exempt roles see ALL rows>` | IS_ROLE_IN_SESSION follows grants | Treating SYSADMIN as a viewer test |
| Placement | shared + private governance | Consumers never get governance | Single schema |
| Refresh | `<actual source mode + task schedule>` | Confirm FULL vs incremental | Assuming a stream after a FULL dynamic table |
| Lifecycle | PASS / PENDING / REJECTED / SKIPPED / FAILED / CANCELLED | PASS after application only | Matched pair equals success |
| Serialisation | `<none / V2 committed mutex>` | Busy later writers; no token steal | Automatic lease expiry |
| Offboarding | revoke SELECT or drop unused role; cancel pending work | Old files must not restore access | Replay historical PASS |
| Reauthorisation | explicit operation if implemented | Blocked generation must not reopen itself | Renamed CSV as reinstatement |
| File handling | exact approved filename | Named format in owned schema | Enumerating all stage files by default |
| Warehouse | `<consumer warehouse if any>` | USAGE is not grant authority | Embedding warehouse grants without authority |

## Objects to record

Record only objects that exist. Typical V2 inventory:

- Admin, auditor and viewer roles
- Shared governed copy with policy arguments (`MAPPING_KEY`, `REMOVED_AT`)
- Mapping, audit, config, request stage, named CSV format
- Durable pair assignments
- V2 requests, submissions, keys/generations, runs, mutex
- Lifecycle procedure plus wrappers; do not call the refresh helper directly
- Task created SUSPENDED
- Isolated QA schemas and durable TEST_RESULTS if used

Legacy `ACCESS_ONBOARD_TRACKER` may still exist beside V2. Do not mix writers.

## How it works

1. Source team refreshes the source. Access-admin never alters it.
2. Refresh snapshots the source, refuses empty/ambiguous identity, merges, soft-deletes missing rows
   and restores returning rows. Mode B keys come from durable pair assignments, not the source.
3. Analyst CSV is uploaded. An explicit onboard call processes that file only.
4. Each parseable row becomes a submission observation. Logical requests are deduplicated. Matched
   unblocked work is applied only after role/grant prerequisites and an atomic
   assignment/mapping/PASS/audit commit.
5. Consumers query the governed copy. SELECT plus no mapping returns zero rows. Last-mapping SELECT
   revocation returns an authorisation error.
6. Offboarding blocks the key, cancels unresolved and applied requests, deletes the mapping and then
   revokes or drops leftover privileges.
7. Interrupted writers leave a committed token. Later calls fail busy until exact-token
   reconciliation. Abort acknowledgement is not unlock permission.

## Who can do what

| Role | Can see | Can change |
|---|---|---|
| Admin | All rows (exempt) | Governance objects and procedures |
| Auditor | All rows if exempt | Nothing beyond granted SELECT |
| Viewer | Mapped live rows only | Nothing |
| Parent of an exempt role | All rows, including unassigned/removed | Per its own grants |
| SELECT, no mapping | Zero rows | Nothing |
| No SELECT | Authorisation error | Nothing |

## Operating it

Run as the access-admin role with `USE SECONDARY ROLES NONE`.

```sql
CALL <GOVERNANCE>.SP_ONBOARD_ACCESS_V2('<file>.csv');
-- Inspect VARIANT status AND request/run/mapping/assignment rows.
CALL <GOVERNANCE>.SP_OFFBOARD_ACCESS_V2('<key>', FALSE);
CALL <GOVERNANCE>.SP_REAUTHORIZE_ACCESS_V2('<key>', '<reason at least 10 chars>');
-- Do not resume the task until acceptance. Do not call the refresh helper directly.
```

Busy means a token is held. Do not delete it. Follow the instance runbook: separate recovery
session, exact writer target, wait for query completion, then incident-specific exact-token unlock.

## Verification

Name the suites actually run. Do not add suite counts together as one production certification.

Record for each check: run id, expected, actual, PASS/FAIL/NOT TESTED, timestamp, code version and
query/error id.

Required classes:

- PENDING then later PASS when the pair arrives
- All child rows for an assigned pair
- Malformed / duplicate / conflicting input
- Viewer isolation with secondary roles NONE
- Zero rows vs last-mapping authorisation error
- Replay after offboarding does not restore access
- Failure/retry, concurrent busy writer
- Isolated abort only if an actual separate writer session was terminated

A restricted session that cannot assume the viewer role is NOT TESTED.

## Known limits

- Compile success or procedure creation is not runtime proof.
- Parser failures may record a FAILED run without each malformed physical line.
- Filename validation is not automatic discovery of new uploads.
- V2 mutex serialises procedure writers; it does not block privileged direct table writes.
- QA reconcile helpers are fixture-specific.
- Session abort can leave the parent CALL `RUNNING` with an epoch END_TIME until that query is
  cancelled and history shows `SQL execution canceled`.
- Account-wide transaction inspection may require privileges the access-admin role does not have.

## Open items

- [ ] Remaining FAIL / NOT TESTED items, with owners
- [ ] Type-contract or identity-stability approvals if conversion was retained
- [ ] Consumer user/warehouse onboarding if out of scope
- [ ] Task remains SUSPENDED until explicit activation
- [ ] Isolated real-data snapshots retained or dropped by approval

## Handover

- Instance names and evidence live in `BUILD_RECORD.md`.
- Reusable contract lives in the skill references, not in a separate update-instructions file.
- Do not rerun CREATE OR REPLACE installation or destructive cleanup to recover missing historical
  evidence.
- Source objects are never dropped as rollback.
