# Comped accounts in the n8n access check

The admin panel can hand out a subscription with **no expiry date at all**:

```
plan: unlimited · status: active · expires_at: NULL · amount: 0
order_reference: admin_comp_<timestamp>
```

`NULL` means *never runs out*. The browser reads it that way — the badge shows
`✦ Unlimited · ∞` instead of counting down. The workflows had to be taught the
same thing, because they are the ones that actually decide.

Applied and verified on 2026-08-10.

## Where the check lives

In `pm-master-generate` the gate is an IF node named **«Дозволити?»**. Its input
comes from **«Active plan?»** (the subscription rows) and it also reaches back to
**«Who is it»** for the account's `created_at`. The same shape appears in
`pm-master-pmp-quiz`, `pm-master-pmbok-summary` and `pm-master-analyze-mom`;
node names there may differ, so check before pasting.

## What it used to say

```js
{{ ($json.expires_at && new Date($json.expires_at) > new Date()) || (new Date($('Who is it').first().json.created_at).getTime() + 7*86400000) > Date.now() }}
```

Read it as: access if the expiry is set *and* still in the future, or the 7-day
trial is still running. A comped row has `expires_at: null`, so the first clause
died on `$json.expires_at` itself, fell through to the trial, and the account was
refused with a 403 — the app then showed "Your Free Trial Has Ended", the exact
opposite of what the grant was for.

## What it says now

```js
{{
  ($json.plan && (new Date($json.expires_at).getTime() || 99999999999999) > Date.now())
  ||
  (new Date($('Who is it').first().json.created_at).getTime()
    + 7*86400000) > Date.now()
}}
```

`new Date(null).getTime()` is `0`, which is falsy, so a missing expiry becomes a
timestamp far in the future and the comparison passes. A real expiry yields a
normal number and behaves exactly as before.

**`$json.plan` is the load-bearing part.** It is what proves a subscription row
came back at all. Without it — writing only `expires_at == null || …` — every
account with no subscription would also match, because their expiry is empty
too, and the trial gate would be gone for everyone. If a workflow's lookup does
not return `plan`, use another field that only a real row carries (`user_id`,
`status`), never the expiry alone.

## The copy-paste trap

Getting this expression in took four tries, all lost to the same thing: pasting
it from a terminal inserts a real newline wherever the display wrapped, and one
landed inside `'Who is it'`. A newline inside a string literal is a syntax
error, so n8n's Result box read `[invalid syntax]` — which looks like a logic
problem and is not one.

Telling them apart, in the expression editor:

| Result box | Meaning |
| --- | --- |
| `[invalid syntax]` | the text does not parse — look for a stray newline before checking the logic |
| `[Execute previous nodes for preview]` | it parses; there is simply no data in this editing session |

To spot the newline: a soft wrap runs to the right edge of the field, a real one
stops short and the next line starts indented. Fixing it is one Backspace before
`it')`. The version above is pre-broken at safe points outside the quotes, so a
further wrap cannot land inside a string.

If the whole field ever reads `[invalid syntax]`, sanity-check the editor with
`{{ $json.plan }}` alone — if that resolves, the field and its braces are fine
and the fault is in the long text.

## Which rows this affects

Only ones an admin created. Real payments always carry a date — n8n writes
`expires_at` when it activates a plan after WayForPay confirms the charge — so
nothing about the paid path changed.

The `subscriptions` RLS policy restricts writes to the admin's own JWT email
(see `supabase_rls_subscriptions.sql`), so a user cannot null out their own
expiry to mint themselves a free account.

## Checking it worked

1. Grant the comp: Users → the row → **♾️ Безліміт**.
2. Hard-reload the app. The badge should read `✦ Unlimited · ∞`, not `· 0d`.
3. Generate a document. It should generate rather than raise the renewal popup.
4. **The regression that matters:** an account with no subscription *and* an
   expired trial must still be refused. If that one starts generating, the
   existence guard is wrong and the product is being given away.
5. Take it back with **✖ Забрати ♾️** and confirm the gate returns.

## One thing to watch

Two identical active rows for the same user reached «Дозволити?» during this
work — one grant that inserted where it should have updated, most likely from an
admin page whose list was loaded before an earlier grant. Harmless while both
went to the False branch; now both go True, so a workflow that acts per item can
do its work twice. Keep one active `expires_at: null` row per account, and
reload the admin page before granting.
