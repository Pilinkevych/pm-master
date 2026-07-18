-- ═══════════════════════════════════════════════════════════════
-- PM Master — Full Schema + RLS Policies
-- Run in Supabase SQL Editor
-- ═══════════════════════════════════════════════════════════════

-- ── 0. Extensions ──────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;


-- ── 1. PMBOK Chunks (RAG) — already exists, just fix RLS ───────
ALTER TABLE IF EXISTS pmbok_chunks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pmbok_public_read" ON pmbok_chunks;
CREATE POLICY "pmbok_public_read"
  ON pmbok_chunks FOR SELECT
  TO anon, authenticated
  USING (true);


-- ── 2. Projects ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS projects (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name          text NOT NULL,
  type          text NOT NULL DEFAULT 'Software',   -- Software, Construction, Marketing, etc.
  status        text NOT NULL DEFAULT 'Planning',   -- Planning, Execution, Monitoring, Closed
  description   text,
  sponsor       text,
  pm_name       text,
  start_date    date,
  end_date_plan date,
  budget        numeric(15,2),                      -- BAC
  currency      text NOT NULL DEFAULT 'USD',
  language      text NOT NULL DEFAULT 'en',
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

CREATE POLICY "projects_select" ON projects FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "projects_insert" ON projects FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "projects_update" ON projects FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "projects_delete" ON projects FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 3. Project Documents (12 PMBOK docs) ───────────────────────
CREATE TABLE IF NOT EXISTS project_documents (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  doc_type     text NOT NULL,   -- charter | scope | wbs | schedule | budget |
                                -- quality | resource | communications | risk |
                                -- procurement | stakeholder | lessons_learned |
                                -- assumption_log | dev_approach | team_plan
  content      jsonb NOT NULL DEFAULT '{}',
  version      int NOT NULL DEFAULT 1,
  generated_at timestamptz,
  created_at   timestamptz DEFAULT now(),
  updated_at   timestamptz DEFAULT now(),
  UNIQUE (project_id, doc_type, version)
);

ALTER TABLE project_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "docs_select" ON project_documents FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "docs_insert" ON project_documents FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "docs_update" ON project_documents FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "docs_delete" ON project_documents FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 4. EVM Snapshots (for progress chart) ──────────────────────
CREATE TABLE IF NOT EXISTS evm_snapshots (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  snapshot_date date NOT NULL DEFAULT CURRENT_DATE,
  pv           numeric(15,2),   -- Planned Value
  ev           numeric(15,2),   -- Earned Value
  ac           numeric(15,2),   -- Actual Cost
  bac          numeric(15,2),   -- Budget at Completion
  note         text,
  created_at   timestamptz DEFAULT now(),
  UNIQUE (project_id, snapshot_date)
);

ALTER TABLE evm_snapshots ENABLE ROW LEVEL SECURITY;

CREATE POLICY "evm_select" ON evm_snapshots FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "evm_insert" ON evm_snapshots FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "evm_update" ON evm_snapshots FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "evm_delete" ON evm_snapshots FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 5. Project Risks ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS project_risks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  risk_id       text,           -- R-001, R-002, ...
  category      text,           -- Technical, Schedule, Budget, Resource, External
  description   text NOT NULL,
  probability   int CHECK (probability BETWEEN 1 AND 5),
  impact        int CHECK (impact BETWEEN 1 AND 5),
  score         int GENERATED ALWAYS AS (probability * impact) STORED,
  response      text,           -- Avoid, Mitigate, Transfer, Accept
  owner         text,
  status        text DEFAULT 'Open',   -- Open, Mitigated, Closed
  created_at    timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

ALTER TABLE project_risks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "risks_select" ON project_risks FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "risks_insert" ON project_risks FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "risks_update" ON project_risks FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "risks_delete" ON project_risks FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 6. Project Team ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS project_team (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id   uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  member_name  text NOT NULL,
  role         text,            -- Project Manager, Developer, BA, QA, ...
  email        text,
  allocation   int DEFAULT 100, -- % of time
  created_at   timestamptz DEFAULT now()
);

ALTER TABLE project_team ENABLE ROW LEVEL SECURITY;

CREATE POLICY "team_select" ON project_team FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "team_insert" ON project_team FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "team_update" ON project_team FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "team_delete" ON project_team FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 7. Project Files (uploaded MoM / email / audio) ────────────
CREATE TABLE IF NOT EXISTS project_files (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id      uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  file_type       text NOT NULL,     -- mom | email | audio | other
  original_name   text,
  storage_path    text,              -- Supabase Storage path
  extracted_data  jsonb,             -- AI-extracted context
  status          text DEFAULT 'pending',  -- pending | processed | error
  created_at      timestamptz DEFAULT now()
);

ALTER TABLE project_files ENABLE ROW LEVEL SECURITY;

CREATE POLICY "files_select" ON project_files FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "files_insert" ON project_files FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "files_update" ON project_files FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY "files_delete" ON project_files FOR DELETE TO authenticated USING (user_id = auth.uid());


-- ── 8. Auto-update updated_at trigger ──────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER projects_updated_at
  BEFORE UPDATE ON projects
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE TRIGGER documents_updated_at
  BEFORE UPDATE ON project_documents
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE TRIGGER risks_updated_at
  BEFORE UPDATE ON project_risks
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ── 9. PMBOK Search RPC (already exists — recreate safely) ─────
CREATE OR REPLACE FUNCTION search_pmbok(
  query_embedding vector(1536),
  match_count int DEFAULT 5
)
RETURNS TABLE(
  id bigint, section text, label text, text text,
  page_start int, page_end int, similarity float
)
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT id, section, label, text, page_start, page_end,
         1 - (embedding <=> query_embedding) AS similarity
  FROM pmbok_chunks
  ORDER BY embedding <=> query_embedding
  LIMIT match_count;
$$;

-- Grant execute to anon and authenticated
GRANT EXECUTE ON FUNCTION search_pmbok TO anon, authenticated;


-- ── 10. Explicit grants (required for new Supabase projects) ────
GRANT SELECT ON pmbok_chunks TO anon, authenticated;
GRANT ALL ON projects TO authenticated;
GRANT ALL ON project_documents TO authenticated;
GRANT ALL ON evm_snapshots TO authenticated;
GRANT ALL ON project_risks TO authenticated;
GRANT ALL ON project_team TO authenticated;
GRANT ALL ON project_files TO authenticated;


-- ═══════════════════════════════════════════════════════════════
-- DONE. Tables created with RLS enabled.
-- Every user sees ONLY their own data.
-- pmbok_chunks is readable by everyone (public PMBOK content).
-- ═══════════════════════════════════════════════════════════════
