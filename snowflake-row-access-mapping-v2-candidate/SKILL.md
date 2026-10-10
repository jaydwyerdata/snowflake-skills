---
name: snowflake-row-access-mapping-v2-candidate
description: Generate a Snowflake row-level security pattern where a mapping table decides which roles can see which rows of a shared table, enforced by a row access policy, with audited procedures to onboard and offboard access from an analyst's CSV, plus a governed copy that survives the source table being rebuilt. Use when groups must see only their own division, region, partner, client or organisation slice, including live BI connections.
---

# Snowflake Row Access Mapping (V2 candidate)

**Status: candidate.** This version adds a lifecycle tracker, durable group-level assignments, a
single-writer mutex, offboarding that cancels pending work, explicit reauthorisation and a recovery
runbook. One worked example, `examples/composite_grain/`, passes its 34 checks; concurrent writers and
session-abort recovery are NOT TESTED. The worked examples in
`../snowflake-row-access-mapping/examples/` implement the older single-record, whole-file-rejection
model and do not validate this version.

Access decisions live in a governed mapping table. A row access policy checks that table on every
query. A nonexempt role with SELECT and no mapping sees zero rows. A role without SELECT receives an
authorisation error instead. These are different tests.

## Read first

Read `references/pattern-design.md` before generating SQL and `references/operating-procedures.md`
before running a workflow. Where the `sql-author` skill is available in Cortex Code, load it for SQL
work. Use the available authenticated session; never require drivers, credentials or local CLI
setup. If SQL execution is unavailable, deliver runnable worksheet SQL and label it unexecuted.

## Existing builds

Read current files AND deployed definitions before editing. Preserve user changes and source data. Do
not rerun installation or cleanup to recover missing test evidence. Verify the mounted workspace. A
populated tracker needs additive migrations, never CREATE OR REPLACE TABLE. Retain legacy audit and
rejection records. Keep installation, migration, deployed code and documentation consistent;
explicitly label any remaining differences. Confirmation already supplied by the user persists.

## Design decisions

Resolve genuinely missing material choices; do not ask again for agreed choices.

| Decision | Required outcome |
|---|---|
| Mode | A: source already owns the key. B: analysts assign it. Do not infer A merely from uncertainty. |
| Source | Exact existing object; read only. Name the source-owning and access-admin teams using user terminology. |
| Identity | Stable row identity, verified with whole-column GROUP BY and NULL checks. Deduplicate exact rows separately. Never generate random refresh IDs. A hash is only as stable as its inputs; use unambiguous encoding. |
| Assignment grain | May differ from physical row grain. A group-level request (for example product plus supplier) applies to all matching physical rows. Analysts supply readable identifiers, not internal hashes. |
| New rows for assigned groups | Persist the business-grain assignment separately and apply it to newly arriving group members; otherwise document and test the gap. |
| CSV | A usually takes key + role. B takes identifiers + key + optional role. Derived names use the agreed prefix/key/suffix and validation before dynamic SQL. |
| Key | One key per row; agree format and conflict/reassignment behaviour. Default deny for unassigned and removed rows except exempt roles. |
| Roles | Admin owns governance and needs CREATE ROLE, not broad MANAGE GRANTS. Optional auditor exemption. Record all inheritance paths: parents of exempt roles see ALL rows. |
| Grants | Database USAGE delegation requires grant authority, e.g. WITH GRANT OPTION. Schema/table ownership grants remain separate. Warehouse USAGE does not imply authority to grant it. |
| Consumer access | User assignment, authentication and warehouse grants are separate consumer onboarding unless explicitly included. Never automatically broaden admin privileges to make them work. |
| Offboarding | Keep unused role and revoke SELECT, or drop it. Prevent old requests and pending work from recreating revoked access. |
| Refresh | Confirm actual source refresh mode and desired freshness. Use a supported schedule, created suspended. A polling schedule is not an after-refresh guarantee. |
| Lifecycle | PASS after successful application; PENDING when valid identifiers are absent from governed data; REJECTED for invalid input. Absence does not prove non-membership. Track submission provenance and duplicate outcomes. |
| Pending trigger | If agreed, recheck existing pending requests on every onboarding call. Filename-based processing is not automatic enumeration of new files. |
| File discovery | Distinguish one explicit file from enumerating all new versions. Agree manifest/content identity before claiming all-file processing. |
| Placement | Shared data and private governance schemas; consumers never receive governance access. Use user-supplied names. |

## Implementation

1. Verify stable identity and grant authority. Do not attribute duplicates to an upstream join
   without evidence.
2. Create the governed copy, mapping/audit/config, request stage and named CSV format, and lifecycle
   tables appropriate to the agreed contract. Preserve source data types unless conversion is
   deliberate.
3. Attach a policy using IS_ROLE_IN_SESSION with distinct argument names; exempt admin so MERGE and
   UPDATE can see governed rows. Hide removed rows from nonexempt viewers.
4. Build snapshot refresh: refuse empty input, verify unique merge keys, insert/update, soft-delete
   absent rows, restore returning rows. Mode B assignments belong to governance, not the source.
5. Build onboarding using the lifecycle contract in the design reference. Validate role names AND
   filenames. Deduplicate both within-file and against durable history; reject conflicting
   assignments.
6. Provision role DDL/grants outside the DML transaction. Atomically commit assignments, mappings,
   successful statuses and audit where possible. Mark failed application explicitly; never call it
   PASS.
7. Offboard access and cancel/supersede pending authorisation work, retaining history and data.
8. Keep scheduled execution suspended until acceptance. Internal stages use READ/WRITE, not USAGE.

Snowflake Scripting traps found in the worked example (pattern design, section 10): prefix procedure
arguments with `:` inside SQL; take run IDs from an `ORDER` sequence before the insert, never
`MAX()` afterwards; fail a run whose file reads zero rows; avoid window-function subqueries in
`UPDATE`; and give viewer roles warehouse access before testing with secondary roles off.

The older `examples/keyed_column/` and `examples/service_tickets/` in the sibling skill folder are
baseline single-record, whole-file-rejection examples. Their historical verification does NOT
validate the composite-grain lifecycle tracker. Do not advertise the latter as production-ready
without running its own tests.

## Verification and handover

Use synthetic fixtures in an isolated schema, preserving deployed behaviour while substituting only
object namespaces. Confirm the execution role explicitly; UI role context may differ from tool
context. Never grant synthetic viewer roles access to live data. Persist observations by run ID with
actual, expected, result, time, tested code version and errors before cleanup.

Required cases: missing pair -> PENDING -> arrival -> PASS on a later call; all group rows assigned;
malformed input; duplicate/rejected resubmission; conflicting requests; role isolation with
secondary roles NONE; no-mapping zero rows; last-mapping SELECT denial; old-file replay after
offboarding; pending cancellation; newly arriving rows for a previously assigned pair; failure/retry
behaviour.

A restricted session that disallows the test role is a blocker. Do not broaden or bypass it. Record
NOT TESTED and provide the exact role test for an authorised session. Compile success is not runtime
success; procedure creation alone does not validate its body. Missing historical values stay NOT
TESTED. Pass GETVARIABLE a literal, uppercase name; use an object of literal GETVARIABLE calls plus GET
for dynamic lookup. Session
variables may not survive moving between worksheets; use durable evidence for new tests.

Cleanup must use an exact run manifest and preserve audit evidence; never broad predicates that match
a whole group's rows, loose audit-text deletion, or a blanket expectation of zero audit rows. Do not
delete real assignments. Finish with `BUILD_RECORD.md` using `references/build-record-template.md`;
append dated corrections, report observed FAIL/NOT TESTED outcomes plainly, and block production
acceptance on security failures. Update this skill and its references directly when asked; an
update-instructions file is not completion.
