-- Reminders for people on the free trial.
--
-- The expiry emails that already exist read `subscriptions`, and a trial user
-- has no row there: the seven days are counted from auth.users.created_at and
-- nothing else. So today the most valuable person on the platform — someone who
-- signed up, used the product for a week and liked it — gets seven days of
-- silence and a paywall on the eighth, with no warning and no reason to come
-- back. This function is what the reminder workflow needs to find them.
--
-- It deliberately mirrors get_subscriptions_expiring: same shape of window, same
-- caller, so the n8n workflow gains two more branches rather than a new design.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────

create or replace function public.get_trials_ending(days_from int, days_to int)
returns table (user_id uuid, email text, trial_ends_at timestamptz, days_left int)
language sql
security definer                     -- auth.users is not readable otherwise
set search_path = public, auth, pg_temp
as $$
  select u.id,
         u.email::text,
         (u.created_at + interval '7 days') as trial_ends_at,
         -- Whole days, floored: someone whose trial ends in twenty hours has one
         -- day left, not zero, and the email should say so.
         floor(extract(epoch from (u.created_at + interval '7 days' - now())) / 86400)::int
  from auth.users u
  where u.email is not null
    -- Anyone who ever paid is the other workflow's business, including someone
    -- whose plan has lapsed: telling them their "trial" is ending would be
    -- wrong and would read as a system that does not know its own customers.
    and not exists (select 1 from public.subscriptions s where s.user_id = u.id)
    and (u.created_at + interval '7 days')
        between now() + (days_from || ' days')::interval
            and now() + (days_to   || ' days')::interval;
$$;

-- Only the service role, from inside n8n. A browser that can call this gets a
-- list of every trial user's email address.
--
-- Both lines are needed, in this order. Revoking from public is what closes the
-- door — but service_role held its own execute right through public and nothing
-- else, so revoking alone locks out n8n as well: the function exists, the key is
-- right, and the call comes back 401. Grant it back explicitly to the one role
-- that should have it.
revoke all on function public.get_trials_ending(int, int) from public, anon, authenticated;
grant execute on function public.get_trials_ending(int, int) to service_role;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. It exists and reads auth.users rather than subscriptions:
--    select prosrc from pg_proc where proname = 'get_trials_ending';
--
-- 2. It finds nobody outside the window and does not error on an empty result:
--    select * from public.get_trials_ending(1, 3);
--
-- 3. The service role can call it. From n8n, or with the service key, this must
--    return rows rather than 401:
--    select has_function_privilege('service_role',
--             'public.get_trials_ending(int, int)', 'execute');   -- expect: t
--
-- 4. It is unreachable from the browser. With the anon key this must fail:
--    curl -s -X POST 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/rpc/get_trials_ending' \
--      -H 'apikey: <the anon key from index.html>' -H 'Content-Type: application/json' \
--      -d '{"days_from":1,"days_to":3}'
--
-- 5. To see it work without waiting a week, backdate one test account and check
--    it appears, then put it back:
--    update auth.users set created_at = now() - interval '5 days'
--     where email = 'your+test@gmail.com';
--    select * from public.get_trials_ending(1, 3);   -- expect that account, 2 days left
--
-- ── WHAT CALLS IT ────────────────────────────────────────────────────────────
-- The n8n workflow "PM Master — Subscription Expiry Emails", daily at 09:00.
-- Two windows: (1, 3) for "two days left" and (-1, 0) for "your trial has
-- ended". The windows overlap the run interval by a day on purpose — a job that
-- fires once daily and matches an exact day loses everyone it misses.
