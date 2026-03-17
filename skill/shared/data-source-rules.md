# Data Source Rules (Shared: Architect + Write)

## NOVITA API ENDPOINT RULE (HARD CONSTRAINT — #1 cause of article errors)

Novita exposes TWO different API endpoints. Every code example MUST use the correct one:

| Endpoint Type | Base URL | Used By |
|---|---|---|
| **OpenAI-compatible** | `https://api.novita.ai/v3/openai` | Python OpenAI SDK, Cursor, Continue, Trae, OpenCode, general API code examples |
| **Anthropic-compatible** | `https://api.novita.ai/anthropic` | Claude Code only (`ANTHROPIC_BASE_URL`) |

**How to pick:** If the code imports `openai` or uses `OpenAI(base_url=...)` → use `/v3/openai`. If the tool sets `ANTHROPIC_BASE_URL` → use `/anthropic`. NEVER mix them.

## NOVITA SETUP DATA SOURCE RULE (HARD CONSTRAINT)

All Novita-related setup steps (env vars, CLI commands, JSON config) **MUST come from the RAG-injected Novita docs** in your context (labeled "Novita AI Integration Guide (from docs)"). Do NOT invent commands or copy from third-party blogs.

## DATA SOURCE MAPPING (HARD CONSTRAINT — causes hallucinated specs if violated)

Every factual claim MUST come from the pre-fetched context. NEVER use your own knowledge for any item in this table.

| Data Type | ONLY Source | Context Marker | Used In |
|-----------|-------------|----------------|---------|
| Parameter count, architecture, config | HuggingFace model card | `--- Model ---`, `Architecture (config.json)` | Model Introduction (all types) |
| Benchmark scores | HuggingFace README tables | `ALL BENCHMARKS`, `KEY STRENGTHS` | Quick Answer, Benchmark tables |
| GGUF quantization sizes / VRAM | Unsloth GGUF repo | `--- Unsloth GGUF Quantization Sizes ---` | Scenario Decision Table, GPU Recs |
| API token pricing | Novita AI API | `>>> USE THIS PRICE <<<` | Cost Analysis, API sections |
| GPU instance pricing | Novita GPU pricing | `--- Novita AI GPU Instance Pricing ---` | Scenario Table, Cost Comparison |
| Provider comparison (pricing, uptime) | OpenRouter | `--- OpenRouter Provider Data ---` | Provider tables (pricing + uptime ONLY, NOT throughput) |
| Throughput, latency, TTFT (ALL providers) | HF Inference Providers ONLY | `--- HuggingFace Inference Providers ---` | Any section mentioning speed/throughput/latency |
| Tool setup steps | Novita RAG docs | `--- Novita AI Integration Guide ---` | How to Access, Setup guides |
| Tips, gotchas, community voices | Web Research (Tavily) | `--- Web Research ---` | Woven into all sections |

**Rules:**
- If context has the data → use it exactly. If context has NO data for an item → write "not publicly disclosed". NEVER guess, round, or substitute from memory.
- **Cite the CORRECT source.** If a number comes from HF → say "HuggingFace", NOT "OpenRouter". NEVER mis-attribute data between sources.
- **Throughput/latency: HuggingFace Inference Providers table ONLY.** Do NOT use throughput numbers from OpenRouter. If both sources appear in context, IGNORE OpenRouter's throughput/latency columns — use HF's `Throughput(t/s)` and `TTFT(s)` columns exclusively.

## VERSION VERIFICATION (CRITICAL — #1 RULE)

- Check if search result is about the EXACT version requested
- **M2 ≠ M2.1, V3 ≠ V3.2, Llama 3.1 ≠ Llama 3.3, Qwen3-Coder ≠ Qwen3-Coder-Next**
- If a source is about the wrong version, SKIP IT COMPLETELY
- EVERY mention of the model must use the EXACT version string the user provided

## MODEL NAME ACCURACY

ALWAYS spell model names exactly as they appear on HuggingFace (e.g., "Qwen3-30B-A3B" not "Qwen3 30B A3B", "DeepSeek-V3-0324" not "Deepseek V3"). Check the repo name and README for the canonical spelling — capitalization, hyphens, and version suffixes must match.

## CODE EXAMPLE RULES (HARD CONSTRAINT)

- Every code snippet MUST be verifiable against official documentation or pre-search data
- Do NOT fabricate API request/response examples, tool-calling schemas, or CLI flags
- Configuration parameters (temperature, sampling) — only include if the tool actually supports them
- If the tool (e.g. Claude Code) does not expose a parameter, do NOT write about configuring it
- Setup commands MUST come from `--- Novita AI Integration Guide ---` in pre-search data
