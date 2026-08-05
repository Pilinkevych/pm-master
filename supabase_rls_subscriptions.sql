-- Row Level Security for `subscriptions`.
--
-- This table decides who has paid, so a write path open to ordinary users is a
-- free Unlimited plan for anyone who opens devtools. The admin panel edits other
-- people's rows through the same public anon key, which means the policy here
-- cannot be the usual `user_id = auth.uid()` — it has to name the admin.
--
-- Run the AUDIT block first and keep the output: it is the only record of what
-- was in force before.

-- ── AUDIT ────────────────────────────────────────────────────────────────────
-- select policyname, cmd, roles, qual, with_check
--   from pg_policies where schemaname='public' and tablename='subscriptions';
-- select grantee, privilege_type from information_schema.role_table_grants
--   where table_name='subscriptions';

-- ── APPLY ────────────────────────────────────────────────────────────────────
alter table public.subscriptions enable row level security;

-- Drop what is there now, so what follows is the whole story.
do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'subscriptions'
  loop
    execute format('drop policy %I on public.subscriptions', p.policyname);
  end loop;
end $$;

-- A user may read their own subscription. That is all a browser ever needs:
-- the badge, the expiry check and the post-payment poll are all reads.
create policy subs_select_own on public.subscriptions
  for select to authenticated
  using (user_id = auth.uid());

-- The admin panel is a browser too, so it needs its own way in. The email comes
-- from the verified JWT, not from anything the page can set.
create policy subs_admin_all on public.subscriptions
  for all to authenticated
  using      ((auth.jwt() ->> 'email') = 'ai.kinomaker@gmail.com')
  with check ((auth.jwt() ->> 'email') = 'ai.kinomaker@gmail.com');

-- Nobody else writes from a browser. n8n activates plans with the service_role
-- key, which bypasses RLS and needs no policy.
revoke all on public.subscriptions from anon, authenticated;
grant select, insert, update on public.subscriptions to authenticated;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- Expect exactly two policies, and no write grant to anon:
-- select policyname, cmd from pg_policies
--   where schemaname='public' and tablename='subscriptions';
--
-- The admin RPCs run as their owner, so they must check the caller themselves.
-- If either is SECURITY DEFINER without an email test in the body, any logged-in
-- user can dump every account:
-- select proname, prosecdef, prosrc from pg_proc
--   where proname in ('admin_get_users','admin_get_subscriptions');
