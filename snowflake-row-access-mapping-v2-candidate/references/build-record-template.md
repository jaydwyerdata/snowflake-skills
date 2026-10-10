# Build record template

Every time this skill is used to build something, finish by writing a build record: one markdown
file, `BUILD_RECORD.md`, in the project the user is working in (never overwrite an existing one;
append a dated section instead). Its job is a documentation trail that someone who was not in the
conversation can pick up cold. Write it from what was actually built and tested in this session, not
from the pattern in general. Plain language, no em dashes.

## Sections, in order

1. **Summary.** Two or three sentences: what was built, for whom, and the date.
2. **Decisions made.** A table: decision, choice made, why, alternative rejected. Include every design
   decision answered with the user (key column, cardinality, key format, role naming convention,
   admin role, hierarchy, bypass roles, offboarding default, assignment mode). Also include:
   - **Assignment grain:** single record ID, or composite (for example product + supplier).
   - **CSV column count:** whether the role name is explicit or derived from the mapping key.
   - **Onboard tracking:** whether the instance uses the lifecycle tracker
     (PASS/PENDING/REJECTED/SKIPPED) or the simpler whole-file rejection model. The tracker is
     recommended when CSV files may contain records not yet present in the data (for example future
     members).
   - **Source deduplication:** whether the refresh deduplicates the source and why.
   - **Refresh trigger:** scheduled cron, stream-triggered from a dynamic table, or on-demand only.
   - **Consumer warehouse:** whether consumer roles use a dedicated warehouse for granular cost
     monitoring, or share the general-purpose warehouse. Record the warehouse name.
3. **Objects created.** A table of every database, schema, table, policy, procedure, task, stage,
   file format and role, with its owner role and one line on what it is for.
4. **How it works.** The data flow in a short numbered list, plus a diagram if one helps.
5. **Who can do what.** Roles, what each can see or change, and the privileges granted to each.
6. **Operating it.** The routine procedures an admin runs, with the exact statements, and what a
   healthy result looks like. Link the operating procedures document.
7. **Verification.** What was tested, how, and the results. Include anything NOT tested.
8. **Known limits and risks.** What the build does not cover and what would break it.
9. **Open items and next steps.** Anything deferred, with an owner if known.
10. **Handover checklist.** What a new owner must know or do on day one: where the code lives, who
    owns what, how to rerun the checks, how to roll back. Rerun and rollback steps must be written for
    a Snowsight worksheet (open each file, run it in order). Never write CLI commands such as
    `snow sql` or SnowSQL.

## Rules

- No CLI commands anywhere in the record. Plain SQL files run in Snowsight or Cortex Code only.
- Keep organisation/account names and real record values out of reusable skill documents. An instance
  build record may use its real object names, but never credentials or unnecessary personal data.
- Say what was built in this instance, using the instance's real object names.
- A claim of "tested" must point to a check that was actually run.
- Record the actual SQL execution role and whether it differs from the UI role or production owner.
- Name durable evidence/run IDs, code provenance, expected/actual results and timestamps. Report
  PASS, FAIL and NOT TESTED separately. Restricted role-switching is NOT TESTED, never an admin
  substitute.
- Record unresolved replay, cancellation, conflict, transaction, filename and assignment-inheritance
  gaps as release blockers. Do not call matched requests successfully applied before grants finish.
- Distinguish persisted statuses from temporary SKIPPED counts and explicit filename handling from
  enumeration of new files. Record unresolved analyst decisions without claiming they are
  implemented.
- Document narrow grant authority: database delegation, source-stage READ, format ownership,
  warehouse grants and quoted user identifiers. Record inherited policy exemptions accurately.
- Confirm actual source refresh mode/task schedule; periodic polling is not an after-refresh
  trigger.
- If an actual abort drill ran, record recovery vs writer session IDs, token identity, abort/cancel
  acknowledgements, the CALL's terminal history (cancelled queries use error text, not only
  EXECUTION_STATUS), and that unlock waited for completion. Same-session client timeouts are
  leftovers, not abort evidence. QA unlock helpers are not production.
- State exact test cleanup scope and retained audit evidence; zero audit rows is not required.
- Use additive migrations and do not rerun installs or destructive deltas to recover lost evidence.
- Update reusable skill files directly and distinguish them from unchanged historical examples.
