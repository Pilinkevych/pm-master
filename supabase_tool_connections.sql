-- Connections to the tools a PM actually works in.
--
-- PM Master knows what a project intends to do. It has never known what it did
-- last week, because it holds no tracker. This is where that comes from: the
-- user connects Jira (and later Trello, Asana, whatever), and the status summary
-- stops being typed from memory.
--
-- Two rules shaped these tables.
--
-- First, the token is not the user's business and not the browser's. A row the
-- browser can read is a row a stolen session can read, so the tokens live in
-- their own table with row level security on and NO policy at all — which means
-- nothing but the service role can touch them, and the service role only exists
-- inside n8n. The browser reads the connection, never the credential.
--
-- Second, access is read-only by intent as well as by scope. Nothing here
-- stores a write token, and the app asks Atlassian for read scopes only. A
-- customer letting a young product into their delivery tool is taking a risk;
-- the least we can do is make the risk one-directional.
--
-- Run this once in the Supabase SQL editor.

-- ── APPLY ────────────────────────────────────────────────────────────────────

-- What the user sees: which tool, which site, when it was connected. No secrets.
create table if not exists public.tool_connections (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  provider      text not null,                    -- 'jira' today; 'trello', 'asana' later
  external_id   text,                             -- Atlassian cloud id of the site
  external_name text,                             -- "acme.atlassian.net", shown in the UI
  scopes        text,                             -- exactly what was granted, for the record
  status        text not null default 'active',   -- active | revoked | error
  error_msg     text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (user_id, provider, external_id)
);

alter table public.tool_connections enable row level security;

drop policy if exists tool_connections_select_own on public.tool_connections;
create policy tool_connections_select_own on public.tool_connections
  for select to authenticated using (user_id = auth.uid());

-- Disconnecting is the user's right and must not need us. Deleting the row
-- cascades to the tokens below, so "Disconnect" genuinely forgets the grant.
drop policy if exists tool_connections_delete_own on public.tool_connections;
create policy tool_connections_delete_own on public.tool_connections
  for delete to authenticated using (user_id = auth.uid());

-- The credentials. No policy on purpose: only the service role reads or writes
-- here. If a select or update policy ever appears on this table, ask why —
-- a browser that can read this table can act as the user inside their Jira.
create table if not exists public.tool_secrets (
  connection_id uuid primary key references public.tool_connections(id) on delete cascade,
  access_token  text not null,
  refresh_token text,
  expires_at    timestamptz,
  updated_at    timestamptz not null default now()
);

alter table public.tool_secrets enable row level security;
revoke all on table public.tool_secrets from anon, authenticated;

-- Which tracker project feeds which PM Master project, and what the tool's
-- statuses mean here. "Done" is a category in Jira, a list name in Trello and a
-- percentage in MS Project, so the mapping belongs to the connection, not to us.
create table if not exists public.project_trackers (
  project_id     uuid primary key references public.projects(id) on delete cascade,
  connection_id  uuid not null references public.tool_connections(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  external_key   text not null,                   -- Jira project key, e.g. FAIR
  external_name  text,
  status_map     jsonb,                           -- {"done":["Done","Closed"],"progress":["In Progress"]}
  last_synced_at timestamptz,
  created_at     timestamptz not null default now()
);

alter table public.project_trackers enable row level security;

drop policy if exists project_trackers_own on public.project_trackers;
create policy project_trackers_own on public.project_trackers
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- The OAuth handshake needs somewhere to remember who started it. The state
-- parameter is the only thing tying the browser that clicked "Connect" to the
-- callback Atlassian sends back, and it has to be unguessable and short-lived —
-- a state that never expires is a replay waiting to happen.
create table if not exists public.oauth_states (
  state      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  provider   text not null,
  created_at timestamptz not null default now()
);

alter table public.oauth_states enable row level security;
revoke all on table public.oauth_states from anon, authenticated;

create or replace function public.purge_oauth_states()
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.oauth_states where created_at < now() - interval '15 minutes';
$$;

revoke all on function public.purge_oauth_states() from public, anon;

-- ── VERIFY ───────────────────────────────────────────────────────────────────
-- 1. Row level security is on for all four:
--    select relname, relrowsecurity from pg_class
--    where relname in ('tool_connections','tool_secrets','project_trackers','oauth_states');
--    -- expected: t for every row
--
-- 2. The tokens are unreachable from a browser. With the anon key this must
--    return an error, not rows:
--    curl -s 'https://ijfawcrcmmvjhilpytsg.supabase.co/rest/v1/tool_secrets?select=access_token' \
--      -H 'apikey: <the anon key from index.html>'
--
-- 3. And the connection list is readable only by its owner:
--    select polname, polcmd from pg_policy
--    where polrelid = 'public.tool_connections'::regclass;
--    -- expected: select and delete, both scoped to auth.uid()
--
-- 4. tool_secrets has no policy at all. This must return no rows:
--    select polname from pg_policy where polrelid = 'public.tool_secrets'::regclass;
--
-- ── WHAT STILL HAS TO BE TRUE OUTSIDE THE DATABASE ───────────────────────────
-- The Atlassian client secret belongs in n8n's credentials and nowhere else —
-- not in index.html, not in a Netlify variable the browser can reach, not in a
-- commit. The scopes requested must stay read-only (read:jira-work,
-- read:jira-user, offline_access). If a write scope ever appears in that list,
-- the promise made to the user on the connect screen is no longer true.
