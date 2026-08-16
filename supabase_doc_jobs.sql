-- Asynchronous document generation.
--
-- A document takes between ninety seconds and two and a half minutes to write.
-- The browser was waiting for that on an open HTTP request, and something
-- between it and n8n closes the connection at roughly two minutes — so the
-- generation succeeded, the workflow returned the text, and nobody received it.
-- It has bitten three times now, each time looking like a different bug: a
-- truncated document, a timeout, a Charter that "did not generate".
--
-- No amount of tuning fixes a race against a fixed ceiling. The quiz already
-- solved this by handing back a job id immediately and writing the result to a
-- table the browser polls. This is the same table for documents.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────

create table if not exists public.doc_jobs (
  id          uuid primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  project_id  uuid,
  doc_key     text not null,
  status      text not null default 'pending',   -- pending | done | error
  content     text,
  error_msg   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists doc_jobs_user_created on public.doc_jobs (user_id, created_at desc);

alter table public.doc_jobs enable row level security;

-- The browser polls its own jobs and nothing else. n8n writes with the service
-- role, which bypasses RLS, so no policy is needed for the workflow side.
drop policy if exists doc_jobs_select_own on public.doc_jobs;
create policy doc_jobs_select_own on public.doc_jobs
  for select to authenticated
  using (user_id = auth.uid());

-- Finished jobs are a copy of a document that already lives in
-- project_documents. Keeping them forever would quietly grow a table nobody
-- reads; an hour is longer than any generation and longer than any poll.
create or replace function public.purge_old_doc_jobs()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.doc_jobs where created_at < now() - interval '1 hour';
$$;

revoke all on function public.purge_old_doc_jobs() from public, anon;
grant execute on function public.purge_old_doc_jobs() to authenticated;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. The table exists with row level security on:
--    select relname, relrowsecurity from pg_class where relname = 'doc_jobs';
--    -- expected: doc_jobs | t
--
-- 2. The policy is there and is SELECT-only:
--    select polname, polcmd from pg_policy
--    where polrelid = 'public.doc_jobs'::regclass;
--    -- expected: doc_jobs_select_own | r
--
-- 3. A signed-in user must not see another account's job. With the anon key
--    this must return no rows rather than every job:
--    curl -s 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/doc_jobs?select=id' \
--      -H 'apikey: <the anon key from index.html>'
--
-- 4. There is no INSERT or UPDATE policy on purpose: only the service role
--    writes here. If a policy for either ever appears, ask why — a browser that
--    can write to this table can hand itself a finished document.
--    select polname, polcmd from pg_policy where polrelid = 'public.doc_jobs'::regclass;
