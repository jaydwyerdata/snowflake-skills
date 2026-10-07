# Build record template

Every time this skill is used to build something, finish by writing a build record: one markdown
file, `BUILD_RECORD.md`, in the project the user is working in (never overwrite an existing one;
append a dated section instead). Its job is a documentation trail that someone who was not in the
conversation can pick up cold. Write it from what was actually built and tested in this session,
not from the pattern in general. Plain language, no em dashes.

## Sections, in order

1. **Summary.** Two or three sentences: what was built, for whom, and the date.
2. **Decisions made.** A table: decision, choice made, why, alternative rejected. Include every
   Step 1 answer (key column, cardinality, key format, role naming convention, admin role,
   hierarchy, bypass roles, offboarding default, assignment mode).
3. **Objects created.** A table of every database, schema, table, policy, procedure, task, stage,
   file format and role, with its owner role and one line on what it is for.
4. **How it works.** The data flow in a short numbered list, plus a diagram if one helps.
5. **Who can do what.** Roles, what each can see or change, and the privileges granted to each.
6. **Operating it.** The routine procedures an admin runs, with the exact statements, and what a
   healthy result looks like. Link the operating procedures document.
7. **Verification.** What was tested, how, and the results. Include anything NOT tested.
8. **Known limits and risks.** What the build does not cover and what would break it.
9. **Open items and next steps.** Anything deferred, with an owner if known.
10. **Handover checklist.** What a new owner must know or do on day one: where the code lives,
    who owns what, how to rerun the checks, how to roll back.

## Rules

- Never include account or organisation identifiers, credentials, or real data values.
- Say what was built in this instance, using the instance's real object names.
- A claim of "tested" must point to a check that was actually run.
