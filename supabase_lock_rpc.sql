-- Close two functions that answer to anyone.
--
-- Found 2026-08-19 while wiring the trial reminders. The reminder workflow calls
-- Supabase with the ANON key — the one published in index.html for the browser —
-- and the functions it calls were left with the execute right PostgreSQL grants
-- to PUBLIC by default. So both were reachable by anyone who opened the site and
-- copied the key out of the page source. Verified from an empty shell:
--
--   curl -X POST .../rpc/get_subscriptions_expiring -d '{"days_from":0,"days_to":3650}'
--   [{"user_id":"…","email":"…","plan":"starter","expires_at":"2026-09-18…"}]
--
-- That is every paying customer's address, plan and renewal date. The second
-- function is worse in kind if not in degree: get_and_expire_subscriptions
-- writes — it marks subscriptions expired — and answered HTTP 200 to the same
-- anonymous call.
--
-- Neither is a browser's business. They exist for one caller: the nightly n8n
-- workflow, which must use the SERVICE key instead.
--
-- Run this once in the Supabase SQL editor, then switch those workflow nodes to
-- the service credential — in that order, or the reminders break for a night.

-- ── APPLY ────────────────────────────────────────────────────────────────────

revoke all on function public.get_subscriptions_expiring(int, int)
  from public, anon, authenticated;
grant execute on function public.get_subscriptions_expiring(int, int)
  to service_role;

revoke all on function public.get_and_expire_subscriptions()
  from public, anon, authenticated;
grant execute on function public.get_and_expire_subscriptions()
  to service_role;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. The right role, and only it:
--    select p.proname,
--           has_function_privilege('anon',          p.oid, 'execute') as anon,
--           has_function_privilege('authenticated', p.oid, 'execute') as authed,
--           has_function_privilege('service_role',  p.oid, 'execute') as service
--    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('get_subscriptions_expiring','get_and_expire_subscriptions','get_trials_ending');
--    -- expected: anon f, authed f, service t — for all three
--
-- 2. And from outside, with the anon key, this must now be refused:
--    curl -s -X POST 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/rpc/get_subscriptions_expiring' \
--      -H 'apikey: <the anon key from index.html>' -H 'Content-Type: application/json' \
--      -d '{"days_from":0,"days_to":3650}'
--    -- expected: {"code":"42501", … "permission denied for function …"}
--
-- ── THE SWEEP WORTH RUNNING ONCE ─────────────────────────────────────────────
-- Anything else in public that anon can execute deserves the same question:
-- does a browser have any business calling it?
--
--    select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon_can
--    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and p.prokind = 'f'
--    order by anon_can desc, p.proname;
--
-- A function that IS meant for the browser (an RPC the app calls as a signed-in
-- user) is fine here — the point is to look at each one and decide, rather than
-- inherit PUBLIC by default. Functions that check the caller inside their own
-- body, like the admin_* ones, are safe by construction; functions that return
-- other people's data are not.
