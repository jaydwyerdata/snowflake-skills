# Snowflake skills

Reusable Snowflake engineering patterns, packaged as agent skills: a `SKILL.md` that tells a coding
agent how to apply the pattern safely, the full design it follows, and a worked example that has
been run live.

Each skill is a folder in the standard skill layout (`SKILL.md` with `name` and `description`
frontmatter, plus supporting files), the format Snowflake documents for Cortex Code skills.

| Skill | What it does | Verified |
|---|---|---|
| [snowflake-cdc-delta-pattern](snowflake-cdc-delta-pattern/) | Snapshot-based change data capture that turns a curated view into an append-only, action-tagged delta table for reverse ETL, with field-level change history, deletes and retention built in | Worked example run live in a Snowflake trial account, 19 of 19 checks passing; loaded and invoked in Cortex Code in Snowsight (7 October 2026) |
| [snowflake-row-access-mapping](snowflake-row-access-mapping/) | Row-level security for one shared table: a mapping table and row access policy decide which roles see which rows, access is onboarded and offboarded from an analyst's CSV with validation, rejection logging and an audit trail, and a governed copy keeps it all intact when the table's owner rebuilds the source. Two modes: key already in the data, or business-assigned | Both worked examples run live in a Snowflake trial account: 31 of 31 and 34 of 34 checks passing (7 October 2026) |

## Using a skill

**Cortex Code in Snowsight, one workspace:** upload the skill's folder to
`.snowflake/cortex/skills/` in a workspace, start a new Cortex Code chat there, and invoke it with
`/` plus the skill name. A workspace skill is only available in the workspace it was added to.

**Cortex Code in Snowsight, account-wide:** once loaded in a workspace, share it to the account's
skill catalog with the built-in `share-skill` skill. It then appears under Skills and plugins and in
the `/` menu across workspaces. Access is granted like any other Snowflake object: in a trial
account it was shared to `PUBLIC` for simplicity, but in a real account scope it to the roles or
users who should be generating these pipelines, since it generates tables, procedures and
scheduled tasks.

**Cortex Code CLI:** copy the folder into a project's `.cortex/skills/` or your user-level
`~/.snowflake/cortex/skills/`.

The skills are plain Markdown and SQL, so they can also be read and applied by hand.

## Principles

- **Never hard-code an account or organisation identifier.** Every object name comes from inputs
  the user gives, or from session context.
- **Ask, don't assume.** Retention windows, keys and delete handling are confirmed with the user,
  never silently defaulted.
- **Leave a documentation trail.** Every skill ends by writing a build record: what was built, why, how it was verified and how to hand it over.
- **Say when not to use it.** Each skill names the cases where a native Snowflake feature is the
  better answer.

## How this was built

These patterns come from problems I hit in real data engineering work, generalised so they carry no
employer detail. I used Claude as a drafting and review partner; the pattern designs and the
decisions in them are mine, and each skill says what was verified and how.

## License

MIT, see [LICENSE](LICENSE).
