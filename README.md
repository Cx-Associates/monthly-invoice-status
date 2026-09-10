# Monthly Invoice Status

A replacement for the shared Excel workbook used for monthly PM/MC/BM invoice
review before billing. Single-page HTML app, Supabase backend, hosted on
GitHub Pages, the same pattern as your other CxA tools.

## What's in this folder

- `index.html`: the whole app (frontend and logic). This is the file you deploy.
- `schema.sql`: everything to run once in Supabase (tables, permissions, the
  trigger that protects the Ajera-sourced columns from non-admin edits).
- `README.md`: this file.

---

## How this works, in plain terms

This section is written so that someone who didn't build the tool, maybe a
future admin, a colleague reviewing it, or you in six months, can understand
what it does without reading the code.

**The problem it solves.** Every month, project managers need to look at
their projects' billing numbers and decide what to bill. That used to happen
in one shared Excel file that everyone edited, with no real way to control
who could change what, and no easy way to see how a project trended over
time. This tool replaces that file with a small web app and a small
database.

**The three things involved:**

1. **The webpage** (`index.html`). This is what a PM sees when they open the
   tool's link in a browser. It has no data of its own; every time it opens,
   it asks the database for whatever it needs to show.
2. **The database** (Supabase). This is where every project's numbers and
   every PM's notes actually live, month after month. It also handles
   logins and is the thing that actually decides who is allowed to change
   what, not the webpage.
3. **The hosting** (GitHub Pages). This is just the address the webpage
   lives at. It doesn't do anything clever; it just serves the file to
   whoever visits the link, the same as any website.

**Why the database, not the webpage, is in charge of permissions.** Because
the webpage's code is visible to anyone who looks (it's a public GitHub
repository), it can't be trusted to be the thing enforcing "only this
person can edit this row." So every permission check that matters is
written as a rule inside the database itself (in `schema.sql`), and those
rules apply no matter what the webpage tries to do. That's the reasoning
behind everything below.

**Who can do what:**

- **Everyone who logs in** can see every project, for context, but that's
  just a viewing convenience, not a real risk, since nothing sensitive
  hinges on hiding a project's numbers from a colleague.
- **A Project Manager, Marketing Contact, or Billing Manager** can edit
  only the projects where their name appears in that role, and only the
  handful of fields meant for them (Requested Bill Amount, Action, Notes,
  and marking a project Reviewed). They cannot change the financial
  numbers that came from Ajera; the database silently refuses that even if
  something in the webpage tried to send it.
- **Admins** (currently you and Cathleen) can edit anything, add new
  people to the tool, and run the monthly import.

**The monthly cycle:**

1. Someone exports the usual data from Ajera, same as today.
2. An admin uploads that export under the Import tab. The tool matches it
   to existing projects by Project ID, refreshes the financial numbers, and
   adds any brand-new projects automatically.
3. PMs, Marketing Contacts, and Billing Managers log in, review their
   projects, and fill in their fields.
4. Admins can check the Submissions tab to see who still has projects left
   to review before invoicing runs.

**Where each piece lives, if something needs checking:**

- Accounts and logins: the Supabase dashboard, under Authentication.
- Project data, notes, and review status: also Supabase, but you'd normally
  look at this through the app itself rather than the raw database.
- The website itself: GitHub, wherever this repository is hosted, under
  Pages.

---

## 1. Set up Supabase

You can reuse your existing Supabase project (`ykddpajaqftrcmmhizoq`) or
create a new one; either works, since none of the table names in
`schema.sql` collide with your other tools (PTO Tracker, Quantified
Benefits, etc).

1. Open your project's **SQL Editor** and run all of `schema.sql`.
2. Go to **Authentication > Users > Invite user** and create an account for
   yourself and for Cathleen Branon-Keogh. This is the one bootstrapping
   step that has to happen outside the app, because nobody can be an admin
   inside the app until at least one admin account exists.
3. Copy each of your **UIDs** from that same screen.
4. Back in the SQL Editor, run an insert like the commented-out example at
   the bottom of `schema.sql`, once, for these two admin accounts only:

   ```sql
   insert into people (id, canonical_name, email, is_admin) values
     ('<eric-auth-uid>', 'Eric Hauser', 'eric@cx-associates.com', true),
     ('<cathleen-auth-uid>', 'Cathleen Branon-Keogh', 'cathleen@cx-associates.com', true);
   ```

5. Go to **Project Settings > API** and copy the **Project URL** and the
   **anon public key**.

That's the only point where you need to touch SQL directly. Every person
after these two (PMs, Marketing Contacts, Billing Managers, or additional
admins) gets added the easier way, described next.

## 2. Adding everyone else (no SQL required)

Once you're logged into the tool as an admin:

1. Invite them in Supabase, same as before (Authentication > Users >
   Invite user). This step still has to happen in Supabase, since creating
   a login isn't something the app itself is allowed to do.
2. Copy their **UID** from that same screen.
3. In the app, go to **People & aliases** and fill in the **Add person**
   form: their name, email, that UID, and whether they should be an admin.
   Click **Add person**.

They can now log in, and once their name matches how they appear in the
Ajera export (or you've added an alias for them), their projects will show
up automatically.

## 3. Point the app at your Supabase project

Open `index.html` and edit these two lines near the top of the `<script>`
block:

```js
const SUPABASE_URL = 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
```

The anon key is safe to expose in client-side code; it's meant to be
public. Actual access control happens through the Row Level Security
policies in `schema.sql`, not by keeping this key secret.

## 4. Deploy to GitHub Pages

Same as your other tools: push this folder to a repo under the
Cx-Associates org, then enable Pages for it (Settings > Pages > Deploy from
branch). Once it's live, share the URL with your PMs.

## 5. First import

1. Log in as an admin.
2. Go to **Import**, pick the month, and upload that month's Ajera export
   (same column layout as `Monthly_Invoice_Status.xlsx`).
3. Confirm the import. Any PM/Marketing Contact/Billing Manager name that
   doesn't match a known account shows up as an unresolved name.
4. Go to **People & aliases** and either map an unresolved name to an
   existing person, or add them as a new person first (see section 2) if
   they don't have an account yet.

From here on, PMs and Marketing Contacts log in, see their own projects by
default (with a toggle to see everyone's, for context), and fill in
Requested Bill Amount, Action, Notes, and Reviewed for their rows. Admins
see everything, plus the Import, People & aliases, and Submissions tabs.

## How the moving pieces fit together

- **Permissions:** enforced at the database level (Row Level Security), not
  just hidden in the UI. A PM can only ever successfully update a row where
  their name is the Project Manager, Marketing Contact, or Billing Manager,
  and even then, a database trigger silently discards any attempt to change
  the Ajera-sourced financial fields, so the UI being tampered with
  client-side can't do anything the database wouldn't already reject.
- **Monthly re-import:** matches by Project ID. Ajera-sourced fields
  (Contract, Billed, Spent, Spend Remaining, Bill Remaining, WIP, and the
  PM/MC/BM names themselves) get refreshed; Requested Bill Amount, Action,
  Notes, and Reviewed status are never touched by an import once set.
- **Projects that disappear from an export:** not deleted; they're left in
  place from the prior import, so nothing vanishes without you noticing.
  (A note: the tool doesn't currently auto-flag "this project vanished this
  month" the way it flags unresolved names; if that turns out to matter in
  practice, it's a small addition to make.)
- **History:** every month's data stays in the same table, so a per-project
  trend view across months is a straightforward addition whenever you want
  it. The data's already structured for it, it's just not built as a chart
  yet beyond the single-month bar chart on the review screen.
- **Adding people:** the one remaining manual step is inviting someone in
  Supabase's own dashboard, since that requires a privileged key that can
  never safely live in this public webpage. Everything after that (creating
  their row in the tool) now happens through the Add person form instead of
  SQL.

## Known limitations worth knowing about

- The Requested Bill Amount, Action, and Notes fields are free-entry per
  role name at first import (no separate approval step), the same trust
  model as the current spreadsheet.
- Password reset uses Supabase's default email flow; there's no custom
  "forgot password" branding.
- The import parser expects the same header names as the current workbook.
  If Ajera's export changes column headers, the parser needs a matching
  update to `EXPECTED_HEADERS` in `index.html`.
- Inviting a new person's login still has to happen in the Supabase
  dashboard rather than inside the app itself; see "Adding people" above
  for why.
