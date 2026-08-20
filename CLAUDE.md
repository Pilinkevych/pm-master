# PM Master — how this project works

Read this before changing anything. It is the handbook for the project, kept in
the repository on purpose: it travels with the code, it is versioned, and it is
loaded automatically at the start of every session.

---

## What it is

A static site — `index.html` is the whole application, roughly half a megabyte,
no build step — plus Supabase for auth and storage and n8n Cloud for everything
that must not run in a browser. Live at **pm-master.club**.

**Push to `main` is a deploy.** Netlify publishes within about a minute. There is
no staging. A rollback is `git revert <sha> && git push`, and it takes the same
minute.

## The pieces

| Piece | Where | Notes |
|---|---|---|
| Application | `index.html` | Landing, app, quiz, demo tour, i18n for 14 languages, all inline |
| Pricing | `pricing.html` | The prices quoted anywhere else must match this file |
| Blog | `blog/` | Written and committed by an n8n workflow, not by hand |
| Database | Supabase project `ijfawcrcmmvjhilpytsg` | Schema and every change live in `supabase_*.sql` here |
| Automation | n8n Cloud `aikinomaker.app.n8n.cloud` | Document generation, quiz, MoM analysis, Jira read, emails, blog |

### n8n workflows that matter

| Workflow | Id | Does |
|---|---|---|
| Generate Document + SLA | `ovNDmGNa0Tnbvdwr` | Every document. Holds the writing rules — see below |
| PMP Quiz (async) | `k50LgUokAOvcM587` | Quiz batches |
| Analyze MoM | `v102VHPwNgppEu0K` | Reads an uploaded kickoff document into project fields |
| Jira Status Pull | `bBPhXyWAPXl8Ckaz` | Reads a Jira project into the four status-report fields |
| Subscription Expiry Emails | `hcPyUo3s5DDnvnzZ` | Daily 09:00: paid expiry + trial reminders |

---

## Invariants — the things that must stay true

**Money is checked, not trusted.** Documents are written by a language model, so
`index.html` reads the finished cost plan back: the stated total against the
approved budget, every approved cost line, the capital/operating split against
the lines it classifies, and the baseline column as a running sum. Any mismatch
raises a banner, and the banner is copied into the exported PDF and Word file.
If you touch `auditBudgetDocument` and its helpers, keep the rule that produced
them: **a banner that fires when nothing is wrong is worse than no banner**, and
each check stays silent when it cannot read the document confidently.

**The generator prompt is the other half.** Rules 1–14 in the `Build Request`
node of the document workflow. The ones that cost the most to learn: numbers in
the source are reproduced, never re-derived (8); one figure has one value across
the document (9); benefit figures that were not given do not exist (11); capital
versus operating is not a coin toss (12); a reserve left out of the funding
schedule has to say so (13); a table written as a sum must add up in the order it
is written (14).

**Access is decided server-side.** Every paid call verifies the caller's token
against Supabase, then asks whether the account is inside its seven-day trial
(`auth.users.created_at + 7 days`) or holds an active subscription. The browser
decides nothing. The same `Дозволити?` node exists in three workflows — change
one, change all three.

**Secrets have exactly one home.** The Supabase service key and the Anthropic key
live in n8n credentials. Never in `index.html`, never in a commit, never pasted
into a chat. The anon key is public by design and belongs in the page.

**Nothing in `public` should answer to `anon` by accident.** PostgreSQL grants
EXECUTE to PUBLIC on new functions, which is how two RPCs ended up returning
every paying customer's email to anyone with the anon key from the page source.
Every function gets `revoke all … from public, anon, authenticated` and then
`grant execute … to service_role`. Both lines, in that order. See
`supabase_lock_rpc.sql`, and run its sweep query when adding functions.

**SQL is applied by hand.** Files here are the record; the user runs them in the
Supabase editor. Each has an APPLY block and a VERIFY block, and the VERIFY block
is not decoration — a trigger that silently failed to attach looks exactly like
one that works.

---

## Things that will bite

**PDF export is a raster.** `html2pdf`/`html2canvas` renders the document to
JPEG, so there is no text layer to select or search. Two consequences: hyphens
inside words are replaced with non-breaking hyphens before export, and cells must
**not** allow word breaking — with both, a line breaks mid-token and the halves
are drawn on top of each other. Word export is real text and has none of this.

**A faded overlay still catches clicks.** The toast fades to `opacity: 0` and
stays in the DOM forever, in the bottom-right corner, which is where the quiz
keeps its Check button. It carries `pointer-events: none` for that reason. Any
new floating element gets the same treatment or is removed from the DOM.

**Answers from a model arrive in whatever shape.** Quiz answer keys come back as
`["B"]`, `"B"` or `"B, D"`; they are normalised once on arrival. Assume the same
of anything else a model returns.

**Documents added to `DOCS` must also be added to the phase list** in
`buildDocsGrid`, or the card is never drawn and nothing says why.

**Jira, right now.** Reading works through a connection held by the workspace —
not per user. The per-account OAuth flow is designed (`supabase_tool_connections.sql`,
the consent screen, the callback URL) but **not built**. The app text says so; do
not let marketing say otherwise. Also: after a Jira import, its search index can
lag by up to twelve hours and the API under-reports — that is Jira, not us.

---

## Known unfinished, deliberately

- Per-user Jira OAuth (above). Tables and consent screen exist; the token
  exchange workflow does not.
- PDF body is an image; moving to the browser's own print engine would fix text
  selection, search and file size.
- `purge_old_doc_jobs()` exists but nothing calls it on a schedule.
- No integration with Trello, Asana, MS Project or anything else. The internal
  shape the status report consumes — seven fields — is what a future adapter
  should target.

---

## Testing that has actually caught things

Generate the full document set from a real kickoff document, then check the cost
plan line by line against it. Sum every table. Open the same document as PDF and
as Word. Run a quiz past 25 questions. Fill all four EVM figures, not just two —
half the panel only wakes up then. Sign up in an incognito window. And look at
the site at 380px wide.

Test artefacts live on the Desktop: `MoM_Fairmont_Line3_Automation_EN.pdf` and
`MoM_Harbour_Point_EHR_Kickoff_EN.pdf`, both with budgets that reconcile exactly,
and `Jira_Fairmont_import.csv` for seeding a tracker.

---

## Working style that fits this project

Small, verified changes. Deploy is instant and public, so verify before pushing:
the inline scripts parse, the arithmetic in any money path is checked with real
numbers, and anything visual is looked at rather than assumed. When something is
wrong, find the cause rather than the symptom — most of this file exists because
a symptom was fixed once and came back wearing a different hat.
