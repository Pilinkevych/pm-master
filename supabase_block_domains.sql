-- Refuse sign-ups from scanner and throwaway domains.
--
-- Prompted by two accounts on the sister project: bee@<random>.oastify.com.
-- That is Burp Collaborator — a domain whose whole purpose is to notice when a
-- server it did not expect makes a request to it. Someone registered to see
-- whether the signup path would fetch a URL, resolve a hostname or parse XML on
-- their behalf. Nothing was generated on either account, so this was a probe,
-- not damage.
--
-- The check belongs here and not in the sign-up form. Whoever does this does not
-- use the form: they POST straight to /auth/v1/signup with the anon key that is
-- published in the page for the browser to use. A trigger on auth.users is the
-- only place that sees every route in — email, Google, magic link, and whatever
-- gets added later.
--
-- The list is a table rather than a literal, so adding a domain at 2am is an
-- INSERT and not a deploy.
--
-- Run this once per Supabase project — this one and AI Metodyst both.

-- ── APPLY ────────────────────────────────────────────────────────────────────

create table if not exists public.blocked_email_domains (
  domain     text primary key,
  reason     text,
  added_at   timestamptz not null default now()
);

alter table public.blocked_email_domains enable row level security;
revoke all on table public.blocked_email_domains from anon, authenticated;

insert into public.blocked_email_domains (domain, reason) values
  -- Out-of-band interaction services: the tooling of someone testing whether
  -- your server can be made to call theirs.
  ('oastify.com',          'Burp Collaborator'),
  ('burpcollaborator.net', 'Burp Collaborator, older domain'),
  ('interact.sh',          'Interactsh'),
  ('oast.pro',             'Interactsh'),
  ('oast.live',            'Interactsh'),
  ('oast.site',            'Interactsh'),
  ('oast.online',          'Interactsh'),
  ('oast.fun',             'Interactsh'),
  ('oast.me',              'Interactsh'),
  ('dnslog.cn',            'DNS logging service'),
  ('requestbin.net',       'Request capture service'),
  ('canarytokens.com',     'Token canary service'),
  -- Throwaway inboxes. This half is a business decision, not a security one: a
  -- seven-day trial plus a disposable address is an unlimited trial. Delete any
  -- row here if you would rather let those through.
  ('mailinator.com',       'Disposable inbox'),
  ('guerrillamail.com',    'Disposable inbox'),
  ('sharklasers.com',      'Disposable inbox'),
  ('yopmail.com',          'Disposable inbox'),
  ('10minutemail.com',     'Disposable inbox'),
  ('temp-mail.org',        'Disposable inbox'),
  ('trashmail.com',        'Disposable inbox'),
  ('dropmail.me',          'Disposable inbox'),
  ('maildrop.cc',          'Disposable inbox'),
  ('getnada.com',          'Disposable inbox')
on conflict (domain) do nothing;

create or replace function public.reject_blocked_email_domain()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  d text;
begin
  d := lower(split_part(coalesce(new.email, ''), '@', 2));
  if d = '' then
    return new;                       -- providers that carry no address at all
  end if;
  -- Both the domain itself and anything under it: Collaborator hands out a new
  -- subdomain per probe, so blocking only the apex would catch nobody.
  if exists (select 1 from public.blocked_email_domains b
             where d = b.domain or d like '%.' || b.domain) then
    raise exception 'email_domain_blocked'
      using hint = 'This email domain is not accepted.',
            errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists block_email_domains on auth.users;
create trigger block_email_domains
  before insert on auth.users
  for each row execute function public.reject_blocked_email_domain();

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. The trigger is attached and enabled ('O'):
--    select tgname, tgenabled from pg_trigger
--    where tgrelid = 'auth.users'::regclass and not tgisinternal;
--
-- 2. A subdomain is refused, which is the case that actually matters:
--    insert into auth.users (id, email)
--    values (gen_random_uuid(), 'bee@0stdvab99oi4kplchzmx32lb026suh.oastify.com');
--    -- expected: ERROR email_domain_blocked
--
-- 3. And an ordinary address still gets in — roll it back:
--    begin;
--    insert into auth.users (id, email) values (gen_random_uuid(), 'someone@gmail.com');
--    rollback;
--
-- ── THE TWO ACCOUNTS ALREADY THERE ───────────────────────────────────────────
-- The trigger only guards new rows. Delete the existing ones by hand:
-- Authentication → Users → search "oastify" → delete. Deleting the auth user
-- cascades to their projects and documents.
--
-- ── ADDING A DOMAIN LATER ────────────────────────────────────────────────────
--    insert into public.blocked_email_domains (domain, reason)
--    values ('something.example', 'why') on conflict do nothing;
-- It takes effect on the next sign-up. No deploy, no restart.
