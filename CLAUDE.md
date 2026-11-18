# Creativa Academy CRM: notes for every session

A child care CRM for Creativa Academy, a preschool in West Miami. The owner runs the school; the office (and teachers,
with less access) use the CRM at crm.creativaacademy.com.

## Rules that always apply

- **Records are kept 5 years (child care records law).** Never delete records about children, families, staff, pay,
  money, the food program, registrations, texts or permission slips: mark them withdrawn, inactive or void instead.
  The database enforces this (`041_record_keeping.sql`, `keep_records`). Never write SQL or code that deletes such
  records, purges old data, or works around the rule. If the owner asks to remove a real mistake, prepare it as a
  one-off SQL file for her to run, using `crm.records_override` inside one transaction, and say what it removes.
- **Ask the owner first** before changing live records, sending any message to families or staff, or publishing
  (merging to `main` publishes crm.creativaacademy.com through Netlify).
- **This repository is public.** Never commit names of children, families or staff, phone numbers, addresses, pay or
  salaries, PINs, account numbers, the school's finances or anything from `data/`. Real data goes only in one-off SQL
  files kept outside the repository and sent to the owner.

## How changes are made

- Schema changes are numbered migrations in `supabase/migrations/`, run by the owner in the Supabase SQL editor:
  idempotent ("safe to run again"), function bodies in single quotes (no dollar-quoting, no backslashes), and the last
  statement is one small check table (the editor shows only the last result). She prefers one all-in-one file.
- The app is plain JavaScript (`app.js`, `styles.css`); new features detect their migration, so the app works before
  it's run. The help guide (`guide.js`) is in English and Spanish; the rest of the screens stay in English.
- Tests: `tests/run-db-tests.sh` (Postgres), `node --test tests/*.mjs`, and `tests/e2e/run.sh` (PostgREST + Chromium).

## The website

The public site is the Netlify project `creativamainsite` (creativaacademy.com). Its code is the GitHub repository
`rocky091500-a11y/creativaacademy`, but some versions were published straight from a folder on the owner's computer,
so check that the GitHub copy matches the live site before preparing an edit, and never publish without her approval.
