-- Turning invite-only back off.
--
-- The product opens to anyone: register, get the seven-day trial, then pay. So
-- the gate that refused a signup from an address nobody had invited has to go.
--
-- Only the trigger is dropped. The invited_emails table and the admin RPCs stay
-- where they are, doing nothing — if access is ever narrowed again (a private
-- beta, an enterprise pilot), re-running supabase_invite_only.sql restores the
-- gate without rebuilding any of it.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────

drop trigger if exists invite_only on auth.users;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. The trigger is gone. This must return no rows:
--    select tgname from pg_trigger
--    where tgrelid = 'auth.users'::regclass and not tgisinternal
--      and tgname = 'invite_only';
--
-- 2. An address nobody invited must now be accepted. This must succeed, so roll
--    it back rather than leaving a stray account behind:
--    begin;
--    insert into auth.users (id, email) values (gen_random_uuid(), 'nobody@example.com');
--    rollback;
--
-- 3. And confirm the dashboard still allows signups, or nothing above matters:
--    Authentication → Sign In / Providers → "Allow new users to sign up" must be on.
--
-- ── WHAT DECIDES ACCESS NOW ──────────────────────────────────────────────────
-- Nothing here. Anyone may create an account; what they can DO is decided by the
-- trial and the subscription, and that check lives in the n8n workflows: every
-- generate/quiz/analyze call verifies the token against Supabase and then asks
-- whether the account is inside its seven days or holds an active plan. The
-- browser is not trusted with that decision and never was.
