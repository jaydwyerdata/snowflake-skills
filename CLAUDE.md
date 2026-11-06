# Snowflake skills

Repo-specific context for Claude Code. General rules come from the user-level CLAUDE.md on this machine; this file only adds what is unique to this project. It may be published, so it must stand alone and follow every public-repo rule (no employer detail, no career framing, no private repo references).

## Purpose

Reusable Snowflake engineering patterns, packaged as agent skills: a `SKILL.md` that tells a coding agent how to apply the pattern safely, the full design it follows, and a worked example run live in a trial account.

## Layout

- `<skill-name>/SKILL.md` : the skill definition a coding agent loads (frontmatter plus instructions)
- `<skill-name>/references/` : pattern design and operating procedures
- `<skill-name>/examples/<name>/` : worked example SQL, walkthrough, assertions and a solution diagram
- `demo-assets/` : gitignored demo prep

## Project specifics

- Every skill is plain Markdown and SQL; no Snowflake CLI or SnowSQL connection is required to read or run one.
- Worked examples run against a Snowflake trial account; object names and data are synthetic, not from any real system.
- Scheduled tasks in worked examples use explicit `Australia/Sydney` cron schedules, never implicit UTC.
- Never hard-code an account or organisation identifier in a skill; object names come from user inputs or session context.

## Status

See each skill's README table entry and `SKILL.md` for what has been verified.
