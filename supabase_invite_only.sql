-- Invite-only access.
--
-- "Continue with Google" has no registration step: the first sign-in IS the
-- signup, and GoTrue writes the row into auth.users before any code of ours
-- runs. So a check in the browser is decoration — the account already exists by
-- the time the page could complain, the JWT is already issued, and PostgREST and
-- the n8n webhooks would accept it. The gate has to sit where the row is
-- written, which is the database.
--
-- A BEFORE INSERT trigger on auth.users refuses any address that is not on the
-- invited list. That covers every route in at once: Google, email/password,
-- magic link, and anything added later — none of them can create a user without
-- going through this insert.
--
-- Note what is deliberately NOT done here: the "Allow new users to sign up"
-- switch in the dashboard stays ON. Turning it off would block invited people
-- too, because an invited person signing in with Google for the first time is
-- performing a signup. The list decides who; the switch cannot tell them apart.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────

create table if not exists public.invited_emails (
  email       text primary key,
  note        text,
  invited_at  timestamptz not null default now()
);

-- Addresses are compared case-insensitively everywhere below, so store them
-- folded and let the primary key reject duplicates that differ only in case.
create or replace function public.normalize_invited_email()
returns trigger
language plpgsql
as $$
begin
  new.email := lower(trim(new.email));
  return new;
end;
$$;

drop trigger if exists invited_emails_normalize on public.invited_emails;
create trigger invited_emails_normalize
  before insert or update on public.invited_emails
  for each row execute function public.normalize_invited_email();

-- Nobody reaches this table from a browser. The trigger below reads it as
-- SECURITY DEFINER, so it does not need any grant to do its job, and the admin
-- panel goes through an RPC rather than touching the table directly.
alter table public.invited_emails enable row level security;
revoke all on table public.invited_emails from anon, authenticated;

-- Seed the two accounts that already exist, or the next sign-in locks you out
-- of your own product. Add the rest of your testers here in the same statement.
insert into public.invited_emails (email, note) values
  ('ai.kinomaker@gmail.com',    'admin'),
  ('yuriy.pilinkevych@gmail.com', 'owner')
on conflict (email) do nothing;

create or replace function public.enforce_invite_only()
returns trigger
language plpgsql
security definer
-- Pinned so nothing on the caller's search_path can shadow the table this
-- decision depends on.
set search_path = public, auth, pg_temp
as $$
begin
  -- An address can arrive null on some provider flows; treat that as not invited
  -- rather than letting it through on a technicality.
  if new.email is null
     or not exists (select 1 from public.invited_emails
                    where email = lower(trim(new.email))) then
    raise exception 'not_invited'
      using hint = 'PM Master is invite-only. Write to support@pm-master.club to request access.',
            errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists invite_only on auth.users;
create trigger invite_only
  before insert on auth.users
  for each row execute function public.enforce_invite_only();

-- Managing the list from the admin panel. Same shape as the other admin RPCs:
-- SECURITY DEFINER with the caller checked inside the body, because a definer
-- function without that check is granted to every signed-in user.
create or replace function public.admin_list_invites()
returns table (email text, note text, invited_at timestamptz)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'ai.kinomaker@gmail.com' then
    raise exception 'Not an admin';
  end if;
  return query select i.email, i.note, i.invited_at
               from public.invited_emails i order by i.invited_at desc;
end;
$$;

create or replace function public.admin_add_invite(target text, note text default null)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'ai.kinomaker@gmail.com' then
    raise exception 'Not an admin';
  end if;
  if target is null or position('@' in target) = 0 then
    raise exception 'That is not an email address';
  end if;
  insert into public.invited_emails (email, note)
  values (target, note)
  on conflict (email) do update set note = excluded.note;
end;
$$;

create or replace function public.admin_remove_invite(target text)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if coalesce(auth.jwt() ->> 'email', '') <> 'ai.kinomaker@gmail.com' then
    raise exception 'Not an admin';
  end if;
  -- Removing an invitation does not remove the account: someone already signed
  -- in keeps their session and their data until you delete the user as well.
  -- This only stops a new signup on that address.
  delete from public.invited_emails where email = lower(trim(target));
end;
$$;

revoke all on function public.admin_list_invites()               from public, anon;
revoke all on function public.admin_add_invite(text, text)       from public, anon;
revoke all on function public.admin_remove_invite(text)          from public, anon;
grant execute on function public.admin_list_invites()            to authenticated;
grant execute on function public.admin_add_invite(text, text)    to authenticated;
grant execute on function public.admin_remove_invite(text)       to authenticated;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- Do not skip these. A trigger that silently failed to attach looks exactly like
-- a trigger that is working, right up until a stranger signs in.
--
-- 1. The trigger exists and is enabled ('O' means enabled):
--    select tgname, tgenabled from pg_trigger
--    where tgrelid = 'auth.users'::regclass and not tgisinternal;
--    -- expected: invite_only | O
--
-- 2. Both existing accounts are on the list, or you lock yourself out:
--    select email, note from public.invited_emails order by email;
--    -- expected: ai.kinomaker@gmail.com, yuriy.pilinkevych@gmail.com
--
-- 3. The list is unreachable from the browser. With the anon key this must
--    return an error, not rows:
--    curl -s 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/invited_emails?select=email' \
--      -H 'apikey: <the anon key from index.html>'
--
-- 4. The gate actually refuses. This must raise 'not_invited':
--    insert into auth.users (id, email) values (gen_random_uuid(), 'nobody@example.com');
--
-- 5. And it must let an invited address through — roll it back afterwards:
--    begin;
--    insert into public.invited_emails (email, note) values ('probe@example.com', 'test');
--    insert into auth.users (id, email) values (gen_random_uuid(), 'probe@example.com');
--    rollback;
--
-- ── TO INVITE SOMEONE ────────────────────────────────────────────────────────
--    insert into public.invited_emails (email, note)
--    values ('tester@example.com', 'beta, cohort 1')
--    on conflict (email) do nothing;
--
-- ── TO TURN THIS OFF AGAIN ───────────────────────────────────────────────────
--    drop trigger invite_only on auth.users;
--    -- the table and the RPCs can stay; without the trigger they do nothing
