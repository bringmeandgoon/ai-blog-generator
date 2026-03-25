#!/bin/bash
# Worker Write Agent: loads context, builds prompt, runs claude -p, handles result
# Sourced by worker.sh — do NOT run directly.

# Prepare generate-phase context: load saved context, strip removed URLs, load outline
# Sets globals: PRE_CONTEXT, ARCHITECT_JSON
prepare_write_context() {
  local JOBID="$1" REMOVED_URLS="$2"

      # Load saved context, skip pre-search
      PRE_CONTEXT=$(cat "$JOBS_DIR/logs/${JOBID}.context" 2>/dev/null)

      # Strip removed URLs from context
      PRE_CONTEXT=$(echo "$PRE_CONTEXT" | strip_removed_urls "$REMOVED_URLS")

      # Detect article type (same logic as worker-search fan-out)
      local TOPIC_FOR_TYPE
      TOPIC_FOR_TYPE=$(cat "$JOBS_DIR/pending/${JOBID}.processing" | python3 -c "import sys,json; print(json.load(sys.stdin)['topic'])" 2>/dev/null)
      ARTICLE_TYPE="platform"
      echo "$TOPIC_FOR_TYPE" | grep -qiE 'vram|\bmemory\b' && ARTICLE_TYPE="vram"
      echo "$TOPIC_FOR_TYPE" | grep -qiE ' vs ' && ARTICLE_TYPE="vs"
      echo "$TOPIC_FOR_TYPE" | grep -qiE 'api.*(provider|pricing|cost|comparison)' && ARTICLE_TYPE="api_provider"
      echo "$TOPIC_FOR_TYPE" | grep -qiE 'how.*(access|use)' && ARTICLE_TYPE="how_to"
      echo "$TOPIC_FOR_TYPE" | grep -qiE '\b(in|with)\s+(opencode|open.code|openclaw|open.claw|claude.code|trae|cursor|continue|codecompanion)\b' && ARTICLE_TYPE="tool_integration"
      echo "$TOPIC_FOR_TYPE" | grep -qiE '\bon\s+(novita|together|replicate|hugging.?face|fireworks|groq|deepinfra)\b|^deploy\b' && ARTICLE_TYPE="platform"

      # Load article type template for write agent
      ARTICLE_TEMPLATE=$(load_template "$ARTICLE_TYPE")
      echo "[worker] [$JOBID] Write: type=$ARTICLE_TYPE, template=$(echo "$ARTICLE_TEMPLATE" | wc -c | tr -d ' ') bytes"

}

# Build the prompt file and run claude -p for article/compare generation
# Sets globals: WRITE_RESULT, WRITE_EXITCODE, WRITE_WARNINGS, WRITE_LOGFILE
run_write() {
  local JOBID="$1" TOPIC="$2" IS_VS="$3" OUTPUT_MODE="$4" ANSWER="$5"

    # Build prompt based on output mode (only reached for phase=generate)
    if [ "$IS_VS" -gt 0 ] && [ "$OUTPUT_MODE" = "compare" ]; then
      # ===== COMPARE MODE (VS): Output structured JSON =====
      echo "[worker] [$JOBID] Mode: Compare JSON"

      # If user answered a clarification question, prepend the answer
      COMPARE_ANSWER_PREFIX=""
      if [ -n "$ANSWER" ]; then
        COMPARE_ANSWER_PREFIX="IMPORTANT: The user was asked a clarification question and answered: \"${ANSWER}\"
Proceed with this answer. Do NOT ask any more questions. Generate the comparison directly.

"
      fi

      # Write prompt to temp file to avoid shell quoting issues with PRE_CONTEXT
      PROMPT_FILE="$JOBS_DIR/logs/${JOBID}.prompt"
      cat > "$PROMPT_FILE" <<COMPARE_PROMPT_EOF
/dev-blog-writer

${COMPARE_ANSWER_PREFIX}Topic: ${TOPIC}

${PRE_CONTEXT}

SEARCH HELPER: /tmp/blog_search_env.sh provides fetch() for additional searches. Usage: source /tmp/blog_search_env.sh && fetch "URL"

TWO TYPES OF DATA ABOVE:
1. FACTUAL DATA — strict source mapping (HARD CONSTRAINT):
   - Architecture, params, benchmarks → HuggingFace ONLY
   - API pricing → Novita AI API data ONLY
   Do NOT use numbers from reference articles or your own knowledge.
2. REFERENCE ARTICLES → Extract practical insights (use cases, strengths/weaknesses analysis, real-world advice). Do NOT copy their numbers.

Generate structured JSON comparison. Use reference articles to enrich the takeaways with practical insights.

OUTPUT FORMAT: You MUST output ONLY valid JSON (no markdown, no code fences, no explanation). The JSON must follow this exact schema:

{
  "type": "comparison",
  "models": {
    "a": { "name": "<full name A>", "color": "#FF6B35" },
    "b": { "name": "<full name B>", "color": "#4A90E2" }
  },
  "benchmarks": [
    { "name": "<benchmark name>", "a": <score>, "b": <score> }
  ],
  "pricing": {
    "a": { "input": <price per 1M input tokens or monthly free tier cost>, "output": <price per 1M output tokens or monthly paid tier cost> },
    "b": { "input": <same>, "output": <same> }
  },
  "params": { "a": <number in billions or null>, "b": <number in billions or null>, "unit": "B" },
  "license": { "a": "<license>", "b": "<license>" },
  "release": { "a": "<date>", "b": "<date>" },
  "context_window": { "a": "<e.g. 1M, 128K>", "b": "<e.g. 1M, 128K>" },
  "takeaways": {
    "a": ["<advantage 1>", "<advantage 2>", ...],
    "b": ["<advantage 1>", "<advantage 2>", ...]
  },
  "summary": "<2-3 sentence comparison summary>",
  "sources": [{ "title": "<source title>", "url": "<url>" }]
}

RULES:
1. Use the PRE-FETCHED DATA above as primary source. If more data is needed, use: source /tmp/blog_search_env.sh && fetch "URL"
2. Use data you found from searching. If a value is not found, use null for numbers and "Unknown" for strings.
3. Include ALL source URLs you visited in the sources array. MUST include Web Research citation URLs.
4. takeaways: list 3-5 key advantages for each side. Enrich with practical insights from Web Research sections.
5. VERSION PRECISION: Model names in the JSON MUST use EXACT version strings from the topic (e.g. "DeepSeek V3.2" NOT "DeepSeek V3"). Pricing MUST match the exact version from Novita API data — do NOT use a different version's price. When searching external sources, verify data is for the EXACT model — not variants like "-Exp", "-Flash", "-Lite". See VARIANT WARNING in pre-fetched data.
6. OUTPUT: PURE JSON ONLY. No text before or after the JSON object.
COMPARE_PROMPT_EOF

    else
      # ===== ARTICLE MODE (all types) =====
      echo "[worker] [$JOBID] Mode: Article HTML"

      # If user answered a clarification question, prepend the answer
      ANSWER_PREFIX=""
      if [ -n "$ANSWER" ]; then
        ANSWER_PREFIX="IMPORTANT: The user was asked a clarification question and answered: \"${ANSWER}\"
Proceed with this answer. Do NOT ask any more questions. Generate the article directly.

"
      fi

      # Build article type template block for the write agent (architect merged in)
      TEMPLATE_BLOCK=""
      if [ -n "$ARTICLE_TEMPLATE" ]; then
        TEMPLATE_BLOCK="
ARTICLE TYPE: ${ARTICLE_TYPE}
STRUCTURE REFERENCE (use as guidance, NOT rigid template):
${ARTICLE_TEMPLATE}
"
      fi

      # Generate data map of raw files available for agent to read
      DATA_MAP=$(python3 << 'DATA_MAP_EOF'
import os, json

D = '/tmp/blog_data'
R = '/tmp/blog_references'
lines = []
lines.append("--- RAW DATA FILES (Read these to verify numbers) ---")
lines.append(f"Directory: {D}/")

desc = {
    '_context.txt': 'Compressed overview (included above — use as roadmap)',
    'hf_detail_a.json': 'HuggingFace model card JSON — architecture, params, license',
    'hf_detail_b.json': 'HuggingFace model card JSON (model B)',
    'config_a.json': 'config.json — exact architecture parameters (layers, heads, vocab)',
    'config_b.json': 'config.json (model B)',
    'readme_a.md': 'Full HuggingFace README — benchmarks, usage examples, details',
    'readme_b.md': 'Full HuggingFace README (model B)',
    'novita.json': 'Novita AI API data — pricing, available models, endpoints',
    '_fanout_queries.json': 'Search queries used (for reference)',
}

if not os.path.isdir(D):
    print("(no data directory)")
    exit()

for f in sorted(os.listdir(D)):
    path = os.path.join(D, f)
    if not os.path.isfile(path) or f.startswith('.'):
        continue
    kb = os.path.getsize(path) // 1024
    if f in desc:
        lines.append(f"  {f} ({kb}KB) — {desc[f]}")
    elif f.startswith('tavily_fanout_'):
        label = f.replace('.json','').replace('tavily_fanout_','#')
        lines.append(f"  {f} ({kb}KB) — fan-out search results {label}")
    elif f.startswith('hf_gguf_'):
        quant = f.replace('hf_gguf_','').replace('.json','')
        lines.append(f"  {f} ({kb}KB) — GGUF {quant} quantization sizes")
    elif f.startswith('hf_'):
        lines.append(f"  {f} ({kb}KB) — HuggingFace data")

lines.append(f"\nReference directory: {R}/")
if os.path.isdir(R):
    for f in sorted(os.listdir(R)):
        p = os.path.join(R, f)
        if os.path.isfile(p):
            kb = os.path.getsize(p) // 1024
            lines.append(f"  {f} ({kb}KB)")
print('\n'.join(lines))
DATA_MAP_EOF
)

      # Write prompt to temp file to avoid shell quoting issues with PRE_CONTEXT
      PROMPT_FILE="$JOBS_DIR/logs/${JOBID}.prompt"
      cat > "$PROMPT_FILE" <<ARTICLE_PROMPT_EOF
${ANSWER_PREFIX}Topic: ${TOPIC}
${TEMPLATE_BLOCK}

DATA OVERVIEW (compressed summary — use as roadmap, verify specifics from raw files):
${PRE_CONTEXT}

${DATA_MAP}

AGENT WORKFLOW — you have full Read/Bash tool access. Follow these steps:

STEP 1 — UNDERSTAND THE DATA:
Read the compressed overview above to understand what data is available. Then read key raw files:
- Architecture/params → Read config_a.json or hf_detail_a.json
- Benchmarks → Read readme_a.md and search for benchmark tables
- VRAM/quantization → Read hf_gguf_*.json files
- Pricing → Read novita.json for exact API pricing
- Community insights → Read tavily_fanout_*.json for original search results
- Extracted articles → Read tavily_extract.json

STEP 2 — IDENTIFY USER QUESTIONS:
From the data (especially Reddit threads, blog comments, community discussions), identify 3-5 KEY QUESTIONS real users are asking about this topic. What problems do they face? What decisions do they need to make?

STEP 3 — PLAN YOUR NARRATIVE:
Design the article structure to ANSWER those questions. Follow the reader's journey:
"What is this?" → "Why should I care?" → "How do I use it?" → "What are the gotchas?" → "What does it cost?"
Use the STRUCTURE REFERENCE above as inspiration — but skip sections with no data, merge related topics, and add angles the template misses.

STEP 4 — WRITE WITH VERIFIED DATA:
For each section, re-read the relevant raw files to get EXACT numbers. Do NOT blindly trust the compressed overview.
Pay attention to source tags: [provider-page] data may be provider-specific, [vendor-blog] may be promotional.

STEP 5 — POLISH:
Read /tmp/blog_references/style-analysis.md and module-templates.md for style guidance.
Ensure the article reads as one coherent story, not disconnected sections.

RULES:
- INLINE CITATIONS: Every price, benchmark, spec MUST have an <a href="SOURCE_URL"> link. Bare numbers = UNACCEPTABLE.
- NOT FOUND → write "not publicly disclosed". NEVER guess or use your own knowledge.
- VERSION PRECISION (#1 RULE):
  * Use the CANONICAL MODEL NAME — NEVER shorten or drop version numbers.
  * For pricing, ONLY use the line marked "USE THIS PRICE" or "◄ THIS ONE".
  * External sources: verify data is for the EXACT model, not a variant (-Exp/-Flash/-Lite/-Mini).
  * Sources list: ONLY include sources about the exact canonical model, actually cited in the article body.
- COMPETITOR SOURCES: [vendor-blog] or competitor domains may be biased. Extract only verifiable facts, NEVER cite as authoritative. Prefer official docs, HuggingFace, Reddit, independent blogs.

--- CORE PRINCIPLES ---
1. Narrative-Driven: single story thread — each section advances the argument
2. Data Accuracy First: every number verified from raw files — never guess
3. Visual-First: tables, charts, callout boxes over text walls. Paragraphs: 2-3 sentences MAX
4. Problem-Oriented: titles and content solve specific problems
5. English Only
6. No Absolute Claims: "among the top" — never "best", "fastest"
7. Code Examples Must Be Verifiable: from official docs or pre-search data only
8. Claude Code: native installer (curl -fsSL https://claude.ai/install.sh | bash) as primary method
9. Novita AI: "all-in-one cloud platform for AI development, offering API access, serverless deployment, and GPU instances"
10. Grammar & Proofreading: check for errors, spelling mistakes, awkward phrasing

--- ARTICLE STRUCTURE ---
- Every article type has ONE hero section — platform→Model Intro, vs→Benchmark+Head-to-Head, vram→VRAM table, tool_integration→Setup+Demos, how_to→API Access, api_provider→Provider Comparison
- Pain Point → Solution narrative chain — build the pain with data before pitching solutions
- Tables are the backbone — minimum 2-3 per article
- Code examples must be complete and runnable — import, init, full call, output handling
- VS articles: each model gets its own Spec table, NOT merged into one two-column table
- VS Head-to-Head: SAME prompt for both models, show actual output differences
- NO generic "Advantages of API" tables (Automation/Scalability = filler)
- NO Quick Answer / Key Highlights popups
- NO Provider-by-Provider breakdown — unified comparison table + one Novita AI deep dive
- OUTLINE COVERAGE: must cover all outline sections and keyPoints. May merge thin sections

--- WRITING RULES ---
- Concise, flowing prose — no bullet points in body paragraphs
- Each paragraph starts with takeaway sentence (conclusion first, evidence follows)
- Technical blog tone — no marketing fluff
- Preserve exact numbers — never round when data is available
- Numbers must be specific — "74.9% on BrowseComp" not "good at browsing"
- Bold the verdict — <strong> for every recommendation
- No filler — cut "In this article, we will explore..."
- H2 TITLES: use question format ("How Much VRAM Does X Need?" > "VRAM Requirements"), include model name, match search patterns
- ANTI-AI (CRITICAL): write like a human engineer sharing findings, NOT an AI summarizing sources.
  BANNED — NEVER use these:
  * "According to [source], ..." / "As mentioned in [source], ..." / "On [source], ..." / "[source] reports that ..." — just state the fact directly, cite with inline <a> link only
  * "The model boasts / features / offers ..." — say what it IS, not what it "offers"
  * "It is worth noting that ..." / "Notably, ..." / "Interestingly, ..." — delete, start with the fact
  * "In the realm of ..." / "In the world of ..." / "When it comes to ..." — get to the point
  * "This means that ..." / "This suggests that ..." — state the implication directly
  * "Let's dive into ..." / "Let's explore ..." / "Let's take a look at ..." — just start writing
  * Listing sources one by one: "Reddit user X said Y. Blog Z mentioned W." — synthesize into ONE conclusion
  * "As shown in the table above/below..." / "The table shows..." — tables speak for themselves, don't narrate them
  DO this instead:
  * Direct assertion: "Qwen3 runs at 147 tok/s on A100 — 2.3x faster than DeepSeek V3."
  * Problem → solution: "Running 70B on consumer GPUs requires quantization. Q4_K_M cuts VRAM from 140GB to 42GB with <2% quality loss."
  * Synthesize, don't attribute: "Community testing confirms Q4_K_M as the sweet spot — minimal quality loss with 70% VRAM savings."
  * Active voice, concrete subjects: "The 128K context window handles full codebases in a single pass."
  The test: if a sentence sounds like a corporate press release or AI summary, rewrite it as something a senior engineer would say to a colleague.
- TABLE-PROSE SEPARATION (CRITICAL):
  * If data is in a table, do NOT repeat the same numbers/specs in surrounding paragraphs
  * Paragraphs before/after a table should add INSIGHT, INTERPRETATION, or CONTEXT — not restate table contents
  * Bad: table has "Q4_K_M: 42GB", paragraph says "Q4_K_M quantization requires 42GB of VRAM"
  * Good: table has "Q4_K_M: 42GB", paragraph says "The sweet spot for single-GPU deployment — fits an A100 with room for 8K context KV cache"
- ANTI-REPETITION (CRITICAL):
  * One fact, one place: a statistic, quote, or insight appears ONCE — in the section where it has the most impact
  * No shared-context restating: if you introduced "262K context window" in the intro, later sections say "the 262K window mentioned above"
  * Community voices are woven, not sprinkled: a Reddit quote in ONE section only — not scattered across 3
  * Forward/backward references: "As we'll see in the cost section below..." or "Building on the setup above..."
- WEB RESEARCH: incorporate community voices, cite ≥3 community/blog URLs, weave into ONE most relevant section

--- OUTPUT FORMAT ---
WordPress-ready HTML:
- <h2> sections, <h3> subsections
- Code: <pre><code class="language-python">...</code></pre>
- HTML tables only — NO markdown tables
- Inline styles (no external CSS)
- Green theme: #CAF6E0 (background), #7CB342 (border/accent)
- External links: target="_blank" rel="noopener"
- Key Insight callout: <div style="background:#CAF6E0;border-left:4px solid #7CB342;padding:12px 16px;margin:16px 0;border-radius:0 8px 8px 0;"><strong>Key Takeaway:</strong> [insight]</div>
- Target: 800-1500 words. Shorter with more visuals > longer with more text

--- POST-PROCESSING (after main body) ---
- Introduction: 2 paragraphs MAX. P1: hook + thesis in bold (Pain Point→Thesis / Question→Answer / Cost Hook / Challenge Framing). P2: preview key evidence
- Conclusion: 1 paragraph + 1 Key Takeaway callout box
- FAQ: 5 questions, 1-2 sentence answers MAX, include exact model version numbers
- SEO Titles: 10 variations, keyword-first, problem-oriented, ≤10 words
- Sources: HuggingFace model card URL (always), Novita AI URL when cited, ≥2 community/blog URLs

--- REFERENCES ---
Read from /tmp/blog_references/:
- style-analysis.md — Title formulas, engagement patterns
- module-templates.md — HTML templates per section type
- style-examples.md — Formatting rules
- post-processing-prompt.md — Intro, Conclusion, FAQ, SEO prompts

OUTPUT: Print to stdout. Start with <h2>. No markdown, no code fences, no markdown tables, no planning text. Do NOT write to files.
ARTICLE_PROMPT_EOF
    fi

    LOGFILE="$JOBS_DIR/logs/${JOBID}.log"
    RESULTFILE="$JOBS_DIR/logs/${JOBID}.result"
    mkdir -p "$JOBS_DIR/logs"

    # Run claude -p in background with timeout protection
    # Read prompt from file to avoid shell quoting issues (context may contain special chars)
    # System prompt: data source constraints only. Writing rules loaded via /dev-blog-writer skill.
    SYSTEM_PROMPT="${DATA_SOURCE_RULES}"
    cat "$PROMPT_FILE" | claude -p \
      --system-prompt "$SYSTEM_PROMPT" \
      --permission-mode bypassPermissions \
      --model "$MODEL" \
      --output-format text >"$RESULTFILE" 2>"$LOGFILE" &
    CLAUDE_PID=$!

    ELAPSED=0
    while kill -0 $CLAUDE_PID 2>/dev/null; do
      sleep 5
      ELAPSED=$((ELAPSED + 5))
      if [ $ELAPSED -ge $CLAUDE_TIMEOUT ]; then
        echo "[worker] [$JOBID] claude -p timed out after ${CLAUDE_TIMEOUT}s, killing PID $CLAUDE_PID"
        kill $CLAUDE_PID 2>/dev/null
        sleep 2
        kill -9 $CLAUDE_PID 2>/dev/null
        break
      fi
    done
    wait $CLAUDE_PID 2>/dev/null
    EXITCODE=$?

    # Run search diagnostics (before removing result file)
    WARNINGS=$(diagnose_search "$LOGFILE" "$RESULTFILE")
    if [ -n "$WARNINGS" ]; then
      echo -e "[worker] [$JOBID] \033[33mSearch warnings: $WARNINGS\033[0m"
    else
      echo "[worker] [$JOBID] Search diagnostics: all checks passed"
    fi

    RESULT=""
    [ -f "$RESULTFILE" ] && RESULT=$(cat "$RESULTFILE")

    # claude -p may store large output in a tool-results file instead of stdout
    # Detect: "[Continue reading the full article in the output file at /path/to/file.txt]"
    TOOLFILE=$(echo "$RESULT" | grep -oE '/[^ \]]+/tool-results/[^ \]]+\.txt' | head -1)
    if [ -n "$TOOLFILE" ] && [ -f "$TOOLFILE" ]; then
      echo "[worker] [$JOBID] Output was in tool-results file, reading: $TOOLFILE"
      RESULT=$(cat "$TOOLFILE")
    fi

    rm -f "$RESULTFILE" "$PROMPT_FILE"

  # Export for caller
  WRITE_RESULT="$RESULT"
  WRITE_EXITCODE="$EXITCODE"
  WRITE_WARNINGS="$WARNINGS"
  WRITE_LOGFILE="$LOGFILE"
}

# Save final result to done file
save_result() {
  local JOBID="$1" RESULT="$2" EXITCODE="$3" WARNINGS="$4" IS_VS="$5" OUTPUT_MODE="$6"

    if [ $EXITCODE -eq 0 ] && [ -n "$RESULT" ]; then
      # Detect clarification question: no <h2> tag AND short output (< 3000 chars)
      RESULT_LEN=$(echo "$RESULT" | wc -c | tr -d ' ')
      HAS_H2=$(echo "$RESULT" | grep -c '<h2>' || true)
      HAS_JSON_MODELS=$(echo "$RESULT" | grep -c '"models"' || true)
      if [ "$HAS_H2" -eq 0 ] && [ "$HAS_JSON_MODELS" -eq 0 ] && [ "$RESULT_LEN" -lt 3000 ]; then
        echo "[worker] [$JOBID] Detected clarification question (${RESULT_LEN} chars, no <h2>)"
        python3 -c "
import json, sys
question = sys.stdin.read()
json.dump({'status': 'clarification', 'question': question}, open('$JOBS_DIR/done/${JOBID}.json', 'w'))
" <<< "$RESULT"
        rm -f "$JOBS_DIR/pending/${JOBID}.processing"
        return
      fi

      if [ "$OUTPUT_MODE" = "compare" ] && [ "$IS_VS" -gt 0 ]; then
        # Validate JSON for compare mode
        VALID_JSON=$(echo "$RESULT" | python3 -c "
import sys, json, re
raw = sys.stdin.read().strip()
raw = re.sub(r'^\s*\`\`\`(?:json)?\s*', '', raw)
raw = re.sub(r'\s*\`\`\`\s*$', '', raw)
start = raw.find('{')
end = raw.rfind('}')
if start >= 0 and end > start:
    candidate = raw[start:end+1]
    obj = json.loads(candidate)
    if 'models' in obj and 'benchmarks' in obj:
        print(json.dumps(obj))
    else:
        print('')
else:
    print('')
" 2>/dev/null)

        if [ -n "$VALID_JSON" ]; then
          python3 -c "
import json, sys
compare_json = sys.stdin.read()
w = '$WARNINGS' or None
json.dump({'status': 'done', 'content': compare_json, 'outputMode': 'compare', 'warnings': w}, open('$JOBS_DIR/done/${JOBID}.json', 'w'))
" <<< "$VALID_JSON"
          echo "[worker] [$JOBID] Done (compare JSON)! ($(echo "$VALID_JSON" | wc -c | tr -d ' ') bytes) at $(date)"
        else
          echo "[worker] [$JOBID] Compare JSON invalid, falling back to article mode"
          python3 -c "
import json, sys
content = sys.stdin.read()
w = '$WARNINGS' or None
json.dump({'status': 'done', 'content': content, 'outputMode': 'article', 'warnings': w}, open('$JOBS_DIR/done/${JOBID}.json', 'w'))
" <<< "$RESULT"
          echo "[worker] [$JOBID] Done (fallback article)! at $(date)"
        fi
      else
        python3 -c "
import json, sys
content = sys.stdin.read()
w = '$WARNINGS' or None
json.dump({'status': 'done', 'content': content, 'warnings': w}, open('$JOBS_DIR/done/${JOBID}.json', 'w'))
" <<< "$RESULT"
        echo "[worker] [$JOBID] Done! ($(echo "$RESULT" | wc -c | tr -d ' ') bytes) at $(date)"
      fi
    else
      python3 -c "
import json
json.dump({'status': 'error', 'error': 'claude exited with code $EXITCODE'}, open('$JOBS_DIR/done/${JOBID}.json', 'w'))
"
      echo "[worker] [$JOBID] Failed (exit $EXITCODE). Check $LOGFILE"
    fi

    rm -f "$JOBS_DIR/pending/${JOBID}.processing"
}
