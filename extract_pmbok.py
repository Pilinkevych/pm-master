# -*- coding: utf-8 -*-
"""
extract_pmbok.py — Витягує структуру PMBOK 8 через Claude Vision
і зберігає в pmbok_toc.json для подальшого імпорту.

Використання:
    python3 extract_pmbok.py pmbok-8.pdf
"""

import os, sys, json, base64, subprocess, tempfile, glob
from pathlib import Path

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
TOC_PAGES = list(range(9, 15))   # сторінки зі змістом (9-14)
RENDER_DPI = 200

def render_pages(pdf_path, pages, tmp_dir):
    paths = []
    for p in pages:
        prefix = f"{tmp_dir}/page_{p:03d}"
        subprocess.run(["pdftoppm", "-jpeg", "-r", str(RENDER_DPI),
                        "-f", str(p), "-l", str(p), str(pdf_path), prefix],
                       capture_output=True)
        imgs = sorted(glob.glob(prefix + "*.jpg"))
        if imgs:
            paths.append(imgs[0])
            print(f"  ✓ Сторінка {p}")
    return paths

def to_b64(path):
    with open(path, "rb") as f:
        return base64.standard_b64encode(f.read()).decode()

def extract_toc(image_paths):
    import anthropic
    client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

    content = []
    for i, p in enumerate(image_paths):
        content.append({"type": "text", "text": f"TOC page {i+1}:"})
        content.append({"type": "image", "source": {
            "type": "base64", "media_type": "image/jpeg", "data": to_b64(p)
        }})

    content.append({"type": "text", "text": """
This is the Table of Contents of PMBOK® Guide 8th Edition.

Extract the FULL structure and return ONLY valid JSON in this format:
{
  "sections": [
    {
      "label": "Section/Chapter title (e.g. '1 Introduction' or '2.1 Stakeholders Performance Domain')",
      "page_start": 1,
      "page_end": 10
    }
  ]
}

Rules:
- Include ALL entries: both The Standard for Project Management AND the PMBOK Guide parts
- Each section = one entry with page_start and page_end
- page_end = page_start of next section minus 1
- For the last section use page_end = 386
- Include appendices
- Return ONLY JSON, no markdown, no explanation
"""})

    resp = client.messages.create(
        model="claude-opus-4-8",
        max_tokens=8000,
        messages=[{"role": "user", "content": content}]
    )
    raw = resp.content[0].text.strip()

    # Parse JSON
    import re
    for pattern in [r"```(?:json)?\s*([\s\S]*?)```", None]:
        try:
            if pattern:
                m = re.search(pattern, raw)
                if m:
                    return json.loads(m.group(1).strip())
            else:
                s, e = raw.index("{"), raw.rindex("}") + 1
                return json.loads(raw[s:e])
        except:
            continue

    raise ValueError(f"Cannot parse JSON:\n{raw[:400]}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 extract_pmbok.py pmbok-8.pdf")
        sys.exit(1)

    if not ANTHROPIC_API_KEY:
        print("❌ Set ANTHROPIC_API_KEY env variable")
        sys.exit(1)

    pdf_path = Path(sys.argv[1])
    print(f"\nPMBOK RAG — Extract Structure")
    print(f"File: {pdf_path.name}\n")

    print("Rendering TOC pages...")
    with tempfile.TemporaryDirectory() as tmp:
        imgs = render_pages(pdf_path, TOC_PAGES, tmp)
        if not imgs:
            print("❌ Failed to render pages")
            sys.exit(1)

        print(f"\nSending {len(imgs)} pages to Claude...")
        structure = extract_toc(imgs)

    sections = structure.get("sections", [])
    print(f"\nExtracted {len(sections)} sections:\n")
    for s in sections:
        print(f"  p.{s['page_start']:3d}-{s['page_end']:3d}  {s['label']}")

    out = pdf_path.with_name("pmbok_toc.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(structure, f, ensure_ascii=False, indent=2)

    print(f"\n✅ Saved: {out}")
    print(f"Next: python3 import_pmbok.py {out}")

if __name__ == "__main__":
    main()
