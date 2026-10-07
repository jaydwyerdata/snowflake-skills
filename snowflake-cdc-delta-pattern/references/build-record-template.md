# Build record template

Every time this skill is used to build a CDC pipeline, finish by writing a build record: one
markdown file, `BUILD_RECORD.md`, in the project the user is working in (never overwrite an existing
one; append a dated section instead). Its job is a documentation trail that someone who was not in
the conversation can pick up cold. Write it from what was actually built and tested in this session,
not from the pattern in general. Plain language, no em dashes.

## Sections, in order

1. **Summary.** Two or three sentences: which feed was built, for which downstream consumer, and the
   date.
2. **Inputs and decisions.** A table: decision, choice made, why, alternative rejected. Include every
   Step 1 and Step 2 answer: source view, use case name, primary key, target database and schema,
   warehouse, daily and housekeeping schedules with timezone, change history retention, delta
   retention, soft-delete grace period, notification integration, and how deletes are signalled.
3. **The source contract.** The curated source view, who owns it, who accepted it, and the full
   column list the record hash and NULL coercion are built on. State plainly that renames and
   restructuring are absorbed at the view, and who to talk to before changing it.
4. **Objects created.** A table of every table, procedure, task and shared log object, with its owner
   role and one line on what it is for.
5. **How it works.** The daily chain in a short numbered list (upsert, delta, snapshot), the weekly
   housekeeping run, and how an insert, an update and a delete each flow through to the delta table.
6. **The delivery contract.** What the downstream consumer reads, the columns and their order, how
   `ACTION` is used, how it should filter by `INSERT_DATE`, and the practical backfill window implied
   by delta retention.
7. **Operating it.** The statements to run an on-demand load, re-run a failed day, check the run log,
   and pause or resume the tasks, with what a healthy result looks like.
8. **Verification.** What was tested, how, and the results. Include anything NOT tested.
9. **Known limits and risks.** What the build does not cover: single-column key, daily cadence,
   sources with native change tracking, anything specific to this build.
10. **Open items and next steps.** Anything deferred, with an owner if known.
11. **Handover checklist.** What a new owner must know or do on day one: where the code lives, who owns
    the source view, how to rerun the checks, how to re-load after an outage longer than delta
    retention, how to roll back.

## Rules

- Never include account or organisation identifiers, credentials, or real data values.
- Say what was built in this instance, using the instance's real object names.
- A claim of "tested" must point to a check that was actually run.
