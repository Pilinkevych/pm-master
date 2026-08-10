# Comped accounts in the n8n access check

The admin panel can now hand out a subscription with **no expiry date at all**:

```
plan: unlimited · status: active · expires_at: NULL · amount: 0
order_reference: admin_comp_<timestamp>
```

`NULL` here means *never runs out*. The browser already reads it that way — the
badge shows `✦ Unlimited · ∞` instead of counting down. **The workflows do not
yet**, and they are the ones that actually decide, so until the change below is
made a comped account will still be refused at generation time.

## Why it fails today

Every generation webhook re-checks the caller's access rather than trusting the
page. Wherever that check compares the stored expiry to now:

```js
// The shape the check has today, whatever the node is called.
const sub = /* row from subscriptions where user_id = … and status = 'active' */;
const ok = sub && new Date(sub.expires_at) > new Date();
```

`new Date(null)` is 1 Jan 1970, so a comped row evaluates as expired and the
webhook answers 403. The page then shows the renewal popup — the exact opposite
of what the grant was for.

## The change

Treat a missing expiry as no expiry:

```js
const sub = /* same row */;
// A comped account has no expiry date. Null is "never", not "1970".
const ok = sub && (sub.expires_at === null || new Date(sub.expires_at) > new Date());
```

Apply it in every workflow that gates on the subscription. As of this writing
that is `pm-master-generate`; if the quiz and Jira export webhooks run the same
check, they each need it too — grep the workflows for `expires_at`.

If the row is fetched with an ordering (to pick the newest of several active
rows), make it `NULLS FIRST` on a descending sort, or the comped row loses to a
dated one:

```sql
order by expires_at desc nulls first limit 1
```

## Which rows this affects

Only ones an admin created. Real payments always carry a date — n8n writes
`expires_at` when it activates a plan after WayForPay confirms the charge, so
nothing about the paid path changes.

The `subscriptions` RLS policy already restricts writes to the admin's own JWT
email (see `supabase_rls_subscriptions.sql`), so a user cannot null out their
own expiry to mint themselves a free account.

## Checking it worked

1. Grant yourself the comp: Users → your row → **♾️ Безліміт**.
2. Reload the app. The badge should read `✦ Unlimited · ∞`, not `· 0d`.
3. Generate a document. Before the change it answers 403 and shows the renewal
   popup; after it, it generates.
4. Take it back with **✖ Забрати ♾️** and confirm the trial/renewal gate returns.
