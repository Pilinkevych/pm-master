# -*- coding: utf-8 -*-
"""
import_pmbok.py — Імпортує PMBOK 8 в Supabase з embeddings для RAG.

Використання:
    python3 import_pmbok.py pmbok_toc.json

Потрібні таблиці в Supabase (SQL нижче):
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE TABLE pmbok_chunks (
        id          bigserial PRIMARY KEY,
        section     text NOT NULL,
        label       text NOT NULL,
        text        text NOT NULL,
        page_start  int,
        page_end    int,
        embedding   vector(1536),
        created_at  timestamptz DEFAULT now()
    );
    CREATE INDEX ON pmbok_chunks USING ivfflat (embedding vector_cosine_ops);
"""

import os, sys, json, time
from pathlib import Path

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY", "")

# Розмір чанка — оптимально для embeddings
MAX_CHUNK_CHARS = 1200
CHUNK_OVERLAP   = 150

def extract_pages_text(pdf_path: Path, page_start: int, page_end: int) -> str:
    """Витягує текст зі сторінок через pdfplumber."""
    import pdfplumber
    texts = []
    with pdfplumber.open(str(pdf_path)) as pdf:
        total = len(pdf.pages)
        for p in range(page_start - 1, min(page_end, total)):
            t = pdf.pages[p].extract_text() or ""
            if t.strip():
                texts.append(t.strip())
    return "\n\n".join(texts)

def chunk_text(text: str, label: str, section: str,
               page_start: int, page_end: int) -> list[dict]:
    """Розбиває текст на чанки з перекриттям."""
    if not text.strip():
        return []

    chunks = []
    words = text.split()
    current = []
    current_len = 0

    for word in words:
        current.append(word)
        current_len += len(word) + 1
        if current_len >= MAX_CHUNK_CHARS:
            chunk_text = " ".join(current)
            chunks.append({
                "section": section,
                "label": label,
                "text": chunk_text,
                "page_start": page_start,
                "page_end": page_end
            })
            # Overlap: залишаємо останні ~CHUNK_OVERLAP символів
            overlap_words = []
            overlap_len = 0
            for w in reversed(current):
                if overlap_len + len(w) > CHUNK_OVERLAP:
                    break
                overlap_words.insert(0, w)
                overlap_len += len(w) + 1
            current = overlap_words
            current_len = overlap_len

    if current:
        chunks.append({
            "section": section,
            "label": label,
            "text": " ".join(current),
            "page_start": page_start,
            "page_end": page_end
        })

    return chunks

def get_embedding(text: str) -> list[float]:
    """Генерує embedding через OpenAI text-embedding-3-small."""
    import httpx
    openai_key = os.environ.get("OPENAI_API_KEY", "")
    if not openai_key:
        # Fallback: повертаємо нульовий вектор (без embeddings)
        return [0.0] * 1536

    resp = httpx.post(
        "https://api.openai.com/v1/embeddings",
        headers={"Authorization": f"Bearer {openai_key}"},
        json={"input": text[:8000], "model": "text-embedding-3-small"},
        timeout=30
    )
    resp.raise_for_status()
    return resp.json()["data"][0]["embedding"]

def upload_chunk(chunk: dict, embedding: list[float]):
    """Завантажує один чанк в Supabase."""
    import httpx
    headers = {
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal"
    }
    payload = {
        "section":    chunk["section"],
        "label":      chunk["label"],
        "text":       chunk["text"],
        "page_start": chunk["page_start"],
        "page_end":   chunk["page_end"],
        "embedding":  embedding
    }
    r = httpx.post(
        SUPABASE_URL.rstrip("/") + "/rest/v1/pmbok_chunks",
        headers=headers,
        json=payload,
        timeout=30
    )
    r.raise_for_status()

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 import_pmbok.py pmbok_toc.json")
        sys.exit(1)

    json_path = Path(sys.argv[1])
    pdf_path = json_path.parent / "pmbok-8.pdf"

    if not json_path.exists():
        print(f"❌ File not found: {json_path}")
        sys.exit(1)
    if not pdf_path.exists():
        print(f"❌ PDF not found: {pdf_path}")
        sys.exit(1)
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("❌ Set SUPABASE_URL and SUPABASE_KEY env variables")
        sys.exit(1)

    with open(json_path, encoding="utf-8") as f:
        structure = json.load(f)

    sections = structure.get("sections", [])
    print(f"\nPMBOK RAG — Import to Supabase")
    print(f"Sections: {len(sections)}\n")

    all_chunks = []
    print("Extracting text from PDF...")
    for sec in sections:
        label = sec["label"]
        p_start = sec.get("page_start", 1)
        p_end   = sec.get("page_end", p_start)

        # Визначаємо top-level section (перше слово до пробілу)
        top_section = label.split(".")[0].strip() if "." in label else label

        print(f"  p.{p_start}-{p_end}  {label[:60]}")
        text = extract_pages_text(pdf_path, p_start, p_end)
        chunks = chunk_text(text, label, top_section, p_start, p_end)
        all_chunks.extend(chunks)
        print(f"          → {len(chunks)} chunks, {len(text)} chars")

    print(f"\nTotal chunks: {len(all_chunks)}")

    use_embeddings = bool(os.environ.get("OPENAI_API_KEY"))
    if not use_embeddings:
        print("⚠️  OPENAI_API_KEY not set — uploading without embeddings")
        print("   (You can add embeddings later)")

    answer = input(f"\nUpload {len(all_chunks)} chunks to Supabase? (yes/no): ").strip().lower()
    if answer not in ("yes", "y"):
        print("Cancelled.")
        sys.exit(0)

    print("\nUploading...")
    errors = 0
    for i, chunk in enumerate(all_chunks):
        try:
            emb = get_embedding(chunk["text"]) if use_embeddings else [0.0] * 1536
            upload_chunk(chunk, emb)
            if (i + 1) % 10 == 0 or i == len(all_chunks) - 1:
                print(f"  {i+1}/{len(all_chunks)} uploaded")
            if use_embeddings:
                time.sleep(0.1)  # rate limit
        except Exception as e:
            print(f"  ❌ Error on chunk {i+1}: {e}")
            errors += 1

    print(f"\n✅ Done! {len(all_chunks) - errors} chunks uploaded, {errors} errors")
    print(f"\nNext: create RPC function in Supabase for semantic search")
    print("""
SQL for search function:
CREATE OR REPLACE FUNCTION search_pmbok(query_embedding vector(1536), match_count int DEFAULT 5)
RETURNS TABLE(id bigint, section text, label text, text text, page_start int, page_end int, similarity float)
LANGUAGE sql STABLE AS $$
  SELECT id, section, label, text, page_start, page_end,
         1 - (embedding <=> query_embedding) AS similarity
  FROM pmbok_chunks
  ORDER BY embedding <=> query_embedding
  LIMIT match_count;
$$;
""")

if __name__ == "__main__":
    main()
