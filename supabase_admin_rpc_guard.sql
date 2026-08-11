-- Closing admin_get_users / admin_get_subscriptions.
--
-- Both were SECURITY DEFINER with nothing in the body asking who was calling.
-- SECURITY DEFINER runs as the owner and bypasses RLS entirely, and EXECUTE on
-- a function is granted to PUBLIC unless revoked — which includes `anon`, the
-- key that ships in the source of every page. So the whole user list was one
-- unauthenticated request away:
--
--   curl -s 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/rpc/admin_get_users' \
--     -X POST -H 'apikey: <the anon key from index.html>' -H 'Content-Type: application/json' -d '{}'
--
-- admin_get_users returns every email and signup date; admin_get_subscriptions
-- adds each account's plan and what they paid.
--
-- supabase_rls_subscriptions.sql already ended with the check that would have
-- caught this ("If either is SECURITY DEFINER without an email test in the
-- body, any logged-in user can dump every account"). It had not been run.

-- ── WHAT WAS IN FORCE BEFORE (audited 2026-08-10) ────────────────────────────
--   admin_get_users()          language sql, SECURITY DEFINER, body: SELECT id,
--                              email, created_at FROM auth.users ORDER BY …
--   admin_get_subscriptions()  language sql, SECURITY DEFINER, body: SELECT …
--                              FROM subscriptions JOIN auth.users ORDER BY …
-- Neither had a WHERE clause, an admin test, or a REVOKE.
--
-- Re-read them at any time with:
-- select pg_get_functiondef(oid) from pg_proc
--  where proname in ('admin_get_users','admin_get_subscriptions');

-- ── APPLY ────────────────────────────────────────────────────────────────────
-- The guard is a WHERE clause rather than an IF, because these are `language
-- sql` and have no procedural body. A non-admin gets an empty result instead of
-- an error, which is all the admin panel needs. The email comes from the
-- verified JWT, so nothing the caller sends can influence it.
--
-- Every reference is alias-qualified: RETURNS TABLE creates OUT parameters with
-- these same names, and unqualified `id` or `created_at` can bind to those
-- instead of to the table.

create or replace function public.admin_get_users()
returns table(id uuid, email text, created_at timestamp with time zone)
language sql
security definer
set search_path = public, auth, pg_temp
as $function$
  SELECT u.id, u.email, u.created_at
  FROM auth.users u
  WHERE coalesce(auth.jwt() ->> 'email', '') = 'ai.kinomaker@gmail.com'
  ORDER BY u.created_at DESC;
$function$;

create or replace function public.admin_get_subscriptions()
returns table(id uuid, user_id uuid, email text, plan text, status text,
              seats integer, amount numeric, currency text,
              created_at timestamp with time zone,
              expires_at timestamp with time zone, order_reference text)
language sql
security definer
set search_path = public, auth, pg_temp
as $function$
  SELECT
    s.id, s.user_id, u.email, s.plan, s.status,
    s.seats,
    COALESCE(s.amount, 0) as amount,
    COALESCE(s.currency, 'USD') as currency,
    s.created_at, s.expires_at,
    COALESCE(s.order_reference, '') as order_reference
  FROM subscriptions s
  JOIN auth.users u ON s.user_id = u.id
  WHERE coalesce(auth.jwt() ->> 'email', '') = 'ai.kinomaker@gmail.com'
  ORDER BY s.created_at DESC;
$function$;

-- Defence in depth: the guard above already returns nothing to a stranger, but
-- an unauthenticated caller should not be able to reach these at all. `anon` is
-- the key in every page; the admin signs in, so `authenticated` is enough.
revoke execute on function public.admin_get_users()         from public, anon;
revoke execute on function public.admin_get_subscriptions() from public, anon;
grant  execute on function public.admin_get_users()         to authenticated;
grant  execute on function public.admin_get_subscriptions() to authenticated;

-- admin_delete_user was written with its check inside the body from the start,
-- but it is in the same family — pin its grants the same way.
revoke execute on function public.admin_delete_user(uuid) from public, anon;
grant  execute on function public.admin_delete_user(uuid) to authenticated;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. All three still SECURITY DEFINER, and now every body names the admin:
-- select proname, prosecdef, prosrc like '%ai.kinomaker@gmail.com%' as has_guard
--   from pg_proc
--  where proname in ('admin_get_users','admin_get_subscriptions','admin_delete_user');
--
-- 2. anon can no longer execute. Expect an error, not a list:
-- curl -s 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/rpc/admin_get_users' \
--   -X POST -H 'apikey: <anon key>' -H 'Content-Type: application/json' -d '{}'
--
-- 3. The admin panel must still list everyone. If it goes empty after this,
--    the signed-in email does not match the literal above — check for a
--    different casing or a second admin account before loosening anything.
