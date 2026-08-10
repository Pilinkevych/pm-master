-- Deleting an account from the admin panel.
--
-- The panel is a browser holding the public anon key, which cannot touch
-- auth.users no matter what RLS says. So the delete runs as a SECURITY DEFINER
-- function — it executes as its owner and bypasses RLS entirely.
--
-- That is exactly why the admin test has to be INSIDE the body. A SECURITY
-- DEFINER function granted to `authenticated` and missing that check would let
-- any signed-in user delete any account, including this one. The same warning
-- already applies to admin_get_users / admin_get_subscriptions; see
-- supabase_rls_subscriptions.sql.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────
create or replace function public.admin_delete_user(target uuid)
returns void
language plpgsql
security definer
-- Pinned so nothing on the caller's search_path can shadow `auth.users` or the
-- tables below with something of its own.
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'ai.kinomaker@gmail.com' then
    raise exception 'Not an admin';
  end if;

  -- Deleting the account you are signed in as locks you out of the panel that
  -- does the deleting. The UI hides the button too; this is the backstop.
  if target = auth.uid() then
    raise exception 'Refusing to delete the admin account';
  end if;

  if not exists (select 1 from auth.users where id = target) then
    raise exception 'No such user';
  end if;

  -- Projects, documents, EVM snapshots, risks, team and files all declare
  -- ON DELETE CASCADE against auth.users, so they go with the row below.
  -- `subscriptions` was created later and its constraint is not in
  -- supabase_schema.sql, so clear it explicitly rather than assume.
  delete from public.subscriptions where user_id = target;
  delete from auth.users where id = target;
end;
$$;

-- Only signed-in callers can even attempt it; the body decides who succeeds.
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- The body must contain the email test. If prosecdef is true and prosrc has no
-- 'ai.kinomaker@gmail.com' in it, stop and fix that before anyone signs in:
-- select proname, prosecdef, prosrc from pg_proc where proname = 'admin_delete_user';
--
-- Signed in as anyone but the admin, this must raise 'Not an admin':
-- select public.admin_delete_user('00000000-0000-0000-0000-000000000000');
