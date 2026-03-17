# Code Agent Integration Article Template

**For articles like: "use [Model] in Claude Code", "[Model] in Cursor", "[Model] with OpenCode"**

## Sections (in this order)

1. **Quick Answer callout** — "Set 3 env vars → restart [Tool] → start coding with [Model]"

2. **Model Introduction** (brief: 2-3 sentences + benchmark table) — What the model is, key strengths for coding
   - 📌 From HF model card `--- Model ---`
   - 📌 Benchmarks from HF README (pick coding-relevant: SWE-bench, LiveCodeBench, Aider)

3. **Why [Tool] + [Model]** — What makes this combination valuable (1-2 paragraphs)

4. **Step-by-step Setup Guide** — Complete setup for the target tool
   - 📌 MUST come from `--- Novita AI Integration Guide ---`
   - Include exact env vars, config files, verification steps

5. **Tool Comparison Table** (if relevant) — Compare 4-5 coding tools, columns: Tool, Type, Setup Difficulty, Best For

6. **Conclusion + FAQ + SEO Titles**

**STRICT SECTION RULES — Code Agent Integration articles ONLY contain these sections listed above.**

**DO NOT INCLUDE any of these sections — they belong to other article types:**
- ❌ "Which Deployment Method" / deployment comparison
- ❌ Provider pricing comparison tables (this is API Provider article territory)
- ❌ Local Deployment / GGUF Quantization (this is VRAM article territory)
- ❌ Cost Comparison: API vs Self-Hosted (this is VRAM/How to Access territory)
- ❌ "How to Access" via web/API/local (this is How to Access article territory)
- ❌ Fabricated tool-calling JSON schemas or API examples not from official docs
- ❌ Configuration parameters (temperature, top-p, top-k) that the tool does not support
- ❌ `ANTHROPIC_TEMPERATURE`, `ANTHROPIC_TOP_P`, `ANTHROPIC_TOP_K` env vars (these do NOT exist for Claude Code)
- ❌ Showing `npm install` as the primary Claude Code install method (use native installer: `curl -fsSL https://claude.ai/install.sh | bash`)

The article focuses on ONE tool (the one in the keyword). Show ONLY how to set it up and use it effectively with the model.

## Thesis Template

"[Model] + [Tool] gives developers [specific advantage] — here's how to set it up in 2 minutes"
