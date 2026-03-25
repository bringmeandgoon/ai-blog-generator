# SEO Blog Generator

AI-powered blog pipeline that writes factually accurate, human-sounding articles about AI models — automatically.

> **Key insight**: AI writing tools hallucinate facts. This pipeline solves that by fetching real data first (HuggingFace specs, live benchmarks, current pricing), then writing from verified sources with inline citations.

![Pipeline Comic](comic/ai-blog-pipeline/01-page-pipeline.png)

## What Makes This Different

Most AI blog tools generate articles from the model's training data — which goes stale and introduces errors. This pipeline inverts the process:

1. **Collect real data first** — HuggingFace model cards, benchmark scores, live provider pricing, Reddit discussions
2. **Build a grounded outline** — every section maps to a specific data source
3. **Write from sources, not memory** — the writer agent follows the outline and cites its sources inline
4. **Verify before publishing** — a separate check agent validates claims against collected data

The result: articles that are accurate on day of publication, with benchmark numbers that match official reports.

## How It Works

```
You type: "GLM-5; GLM-5 VRAM; GLM-5 vs Kimi K2.5; GLM-5 API providers"
                              ↓
              5-Agent Pipeline (fully automated)
                              ↓
        3-4 complete HTML articles with source citations
```

| Agent | What it does |
|-------|-------------|
| **Search** | Fetches model specs from HuggingFace, benchmarks from README tables, pricing from provider APIs, community takes from Reddit/Twitter |
| **Architect** | Builds structured outline — each section gets assigned a data source, prevents hallucination by design |
| **Write** | Generates full HTML following the outline, with `<a href>` citations pointing to real sources |
| **Check** | Cross-validates claims: benchmark numbers, model sizes, pricing — flags discrepancies before publish |
| **Rewrite** | Removes AI writing patterns — hedging language, em-dash overuse, unnaturally formal sentences |

## Quick Start

```bash
# 1. Setup (checks deps, installs packages)
bash setup.sh

# 2. Configure .env
#    PPIO_API_KEY      — check + rewrite agents (MiniMax via PPIO)
#    TAVILY_API_KEY    — web search fallback
#    WP_SITE_URL / WP_USER / WP_APP_PASSWORD  — publish to WordPress

# 3. Start
./start.sh
```

Open **http://localhost:3001**

## Requirements

- **Node.js** 18+
- **Python** 3.9+
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- macOS recommended (Linux works with minor tweaks)

## Project Structure

```
├── worker.sh              # Dispatcher — routes jobs to agents
├── worker-search.sh       # Search Agent — data collection
├── worker-architect.sh    # Architect Agent — outline generation
├── worker-write.sh        # Write Agent — article generation
├── worker-check.sh        # Check Agent — fact validation
├── worker-rewrite.sh      # Rewrite Agent — humanization
│
├── skill/                 # Agent prompt rules
│   ├── write-rules.md     # Writing constraints (what to write, what to avoid)
│   ├── check-rules.md     # Validation rules (10 quality categories)
│   ├── rewrite-rules.md   # Humanization rules
│   ├── templates/         # Article type templates (VRAM, vs, API, how-to...)
│   ├── shared/            # Shared data source rules
│   └── references/        # Style guides, examples
│
├── scripts/               # Extracted Python modules
│   ├── search_context.py  # HuggingFace + benchmark extraction (main search)
│   ├── search_perplexity.py  # Perplexity API multi-query search
│   ├── search_fanout.py   # Query generation
│   ├── search_review.py   # Search quality scoring
│   ├── search_more.py     # Follow-up search on feedback
│   ├── parse_openrouter.py   # OpenRouter provider data
│   └── search_providers.py   # Multi-provider pricing
│
├── novita-docs/           # RAG knowledge base (~200 Novita AI docs)
├── seo-monitor/           # SEO tracking (GSC data)
└── src/                   # React frontend
```

## Anti-Hallucination Design

The pipeline is structured to prevent factual errors at each stage:

- **Search**: Uses `safetensors.total` for model size (not README text, which is often wrong for MoE models); extracts benchmark scores from both tables and inline text
- **Outline**: each section includes `[SOURCE: ...]` annotation — writer can't invent a claim without a source
- **Check**: validates key facts — if article says "72B parameters" but data says "70B", it flags and corrects
- **Rewrite**: final pass removes hedging phrases ("it's worth noting", "as of my knowledge cutoff") and AI-signature patterns

## Article Types Supported

| Type | Example |
|------|---------|
| VRAM requirements | "GLM-5 VRAM: minimum hardware to run locally" |
| Model comparison | "GLM-5 vs Kimi K2.5: benchmark comparison" |
| API provider guide | "GLM-5 API: best providers and pricing" |
| How-to access | "How to use GLM-5 for free" |
| Tool integration | "Use GLM-5 in Open WebUI" |
| Platform guide | "GLM-5 on Hugging Face: complete guide" |
