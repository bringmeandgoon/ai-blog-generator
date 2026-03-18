#!/bin/bash
# Worker Write Agent: loads context, builds prompt, runs claude -p, handles result
# Sourced by worker.sh — do NOT run directly.

# Prepare generate-phase context: load saved context, strip removed URLs, fetch new outline URLs
# Sets globals: PRE_CONTEXT, ARCHITECT_JSON
prepare_write_context() {
  local JOBID="$1" REMOVED_URLS="$2"

      # Load saved context, skip pre-search
      PRE_CONTEXT=$(cat "$JOBS_DIR/logs/${JOBID}.context" 2>/dev/null)

      # Strip removed URLs from context
      PRE_CONTEXT=$(echo "$PRE_CONTEXT" | strip_removed_urls "$REMOVED_URLS")

      # Load architect outline if it exists (from the architect phase)
      ARCHITECT_JSON=""
      EDITED_OUTLINE=$(cat "$JOBS_DIR/pending/${JOBID}.processing" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('editedOutline',{})))" 2>/dev/null)
      if [ -f "$JOBS_DIR/logs/${JOBID}.architect.json" ]; then
        if [ -n "$EDITED_OUTLINE" ] && [ "$EDITED_OUTLINE" != "{}" ] && [ "$EDITED_OUTLINE" != "null" ]; then
          ARCHITECT_JSON="$EDITED_OUTLINE"
          echo "[worker] [$JOBID] Using user-edited outline"
        else
          ARCHITECT_JSON=$(cat "$JOBS_DIR/logs/${JOBID}.architect.json" 2>/dev/null)
          echo "[worker] [$JOBID] Using architect-generated outline"
        fi
      fi

      # Fetch text content for any new URLs in the outline that aren't in context
      if [ -n "$ARCHITECT_JSON" ] && [ "$ARCHITECT_JSON" != "{}" ]; then
        source /tmp/blog_search_env.sh
        NEW_URLS_CONTENT=$(OUTLINE_JSON="$ARCHITECT_JSON" EXISTING_CTX="$PRE_CONTEXT" python3 << 'FETCH_NEW_EOF'
import json, os, re, subprocess, sys

outline_raw = os.environ.get('OUTLINE_JSON', '{}')
existing_ctx = os.environ.get('EXISTING_CTX', '')

try:
    outline = json.loads(outline_raw)
except:
    exit(0)

# Collect all URLs from outline dataSources
all_urls = []
for sec in outline.get('sections', []):
    for ds in sec.get('dataSources', []):
        url = ds.get('url', '')
        if url:
            all_urls.append(url)

if not all_urls:
    exit(0)

# Find URLs not already mentioned in existing context
new_urls = [u for u in all_urls if u not in existing_ctx]
if not new_urls:
    exit(0)

# Deduplicate while preserving order
seen = set()
unique_new = []
for u in new_urls:
    if u not in seen:
        seen.add(u)
        unique_new.append(u)

print(f"[fetch-new] {len(unique_new)} new URLs to fetch", file=sys.stderr, flush=True)

# Fetch each URL, extract text
curl_bin = "/opt/homebrew/opt/curl/bin/curl"
proxy_port = ""
try:
    r = subprocess.run(["scutil", "--proxy"], capture_output=True, text=True, timeout=5)
    for line in r.stdout.split("\n"):
        if "HTTPPort" in line:
            p = line.split(":")[-1].strip()
            if p and p != "0":
                proxy_port = p
except:
    pass

results = []
for url in unique_new[:8]:  # max 8 new URLs
    try:
        cmd = [curl_bin, "-sL", "--max-time", "15",
               "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]
        if proxy_port:
            cmd.extend(["-x", f"http://127.0.0.1:{proxy_port}"])
        cmd.append(url)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        html = r.stdout
        if not html or len(html) < 100:
            continue

        # Strip HTML to plain text
        text = html
        # Remove script/style blocks
        text = re.sub(r'<script[^>]*>[\s\S]*?</script>', '', text, flags=re.I)
        text = re.sub(r'<style[^>]*>[\s\S]*?</style>', '', text, flags=re.I)
        # Remove HTML tags
        text = re.sub(r'<[^>]+>', ' ', text)
        # Decode entities
        import html as html_lib
        text = html_lib.unescape(text)
        # Collapse whitespace
        text = re.sub(r'[ \t]+', ' ', text)
        text = re.sub(r'\n\s*\n', '\n\n', text)
        text = text.strip()

        # Truncate per URL (keep first 3000 chars)
        if len(text) > 3000:
            text = text[:3000] + "..."

        if len(text) > 100:
            results.append(f"[{url}]\n{text}")
            print(f"[fetch-new] Fetched {url} ({len(text)} chars)", file=sys.stderr, flush=True)
        else:
            print(f"[fetch-new] Skipped {url} (too short after extraction)", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"[fetch-new] Failed {url}: {e}", file=sys.stderr, flush=True)

if results:
    print("\n--- Additional Sources (user-added URLs) ---")
    print("\n\n".join(results))
    print("")
FETCH_NEW_EOF
)
        if [ -n "$NEW_URLS_CONTENT" ]; then
          PRE_CONTEXT="${PRE_CONTEXT}
${NEW_URLS_CONTENT}"
          echo "[worker] [$JOBID] Fetched new URL content ($(echo "$NEW_URLS_CONTENT" | wc -c | tr -d ' ') bytes)"
        fi
      fi

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

      # Build outline injection block if architect outline exists
      OUTLINE_BLOCK=""
      if [ -n "$ARCHITECT_JSON" ] && [ "$ARCHITECT_JSON" != "{}" ] && [ "$ARCHITECT_JSON" != "null" ]; then
        OUTLINE_BLOCK="
ARTICLE OUTLINE (coverage guide — NOT a rigid contract):
${ARCHITECT_JSON}

OUTLINE USAGE:
- The outline tells you WHAT topics to cover and WHICH sources to cite — use it as a coverage checklist
- You decide HOW to structure the narrative. You MAY merge, reorder, or split sections if it improves flow
- Build a SINGLE NARRATIVE THREAD: each section should build on the previous one, not repeat shared context
- A fact/quote/insight should appear ONCE in the most relevant section — NEVER repeat across sections
- If the outline assigns the same source to multiple sections, decide which section benefits most and cite it there only
- You MAY skip a section if it has no meaningful data support or would be redundant
- Inline-cite source URLs from dataSources wherever you state facts
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
    'tavily_extract.json': 'Extracted full-text content from key source URLs',
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

${OUTLINE_BLOCK}

DATA OVERVIEW (compressed summary — use as roadmap, verify specifics from raw files):
${PRE_CONTEXT}

${DATA_MAP}

AGENT WORKFLOW — you have full Read/Bash tool access, USE IT:
1. The compressed overview above gives you the big picture and section plan
2. Before writing each section, READ the relevant raw data files to get exact numbers:
   - Architecture/params → Read config_a.json or hf_detail_a.json
   - Benchmarks → Read readme_a.md and search for benchmark tables
   - VRAM/quantization → Read hf_gguf_*.json files
   - Pricing → Read novita.json for exact API pricing
   - Community insights → Read tavily_fanout_*.json for original search results with full context
   - Extracted article content → Read tavily_extract.json
3. VERIFY every number you write against the raw file — do NOT blindly trust the compressed overview
4. Pay attention to source tags in the overview: [provider-page] data may be provider-specific, [vendor-blog] may be promotional
5. Reference files at /tmp/blog_references/ have style guides — read style-analysis.md and module-templates.md before writing

RULES:
- INLINE CITATIONS: Every price, benchmark, spec MUST have an <a href="SOURCE_URL"> link. Bare numbers = UNACCEPTABLE.
- NOT FOUND → write "not publicly disclosed". NEVER guess or use your own knowledge.
- VERSION PRECISION (#1 RULE):
  * Use the CANONICAL MODEL NAME from the box at the top — NEVER shorten or drop version numbers.
  * For pricing, ONLY use the line marked "USE THIS PRICE" or "◄ THIS ONE". Lines marked "reference only" are OTHER versions.
  * External sources: verify data is for the EXACT model, not a variant (-Exp/-Flash/-Lite/-Mini). See VARIANT WARNING.
  * Sources list: ONLY include sources about the exact canonical model, actually cited in the article body.
- COMPETITOR FILTER: Sources tagged [vendor-blog] or from competitor domains (haimaker.ai, etc.) may contain biased/promotional content. Extract only verifiable technical facts, NEVER cite them as authoritative. Prefer official docs, HuggingFace, Reddit, and independent blogs.
- WEB RESEARCH: Incorporate tips/gotchas/community voices from search results. Cite at least 3 community/blog URLs. Weave community opinions into the ONE most relevant section — do NOT scatter the same quote across multiple sections.
- NO REPETITION: Each fact, quote, or statistic appears ONCE. Later sections reference earlier context ("as noted above") instead of restating.
- NARRATIVE FLOW: The article should read as a guided journey, not independent sections. Each H2 builds on the previous. Use transitions.
- MANDATORY SOURCES: The HuggingFace model card URL (from the "--- Model ---" section) MUST always appear in the Sources list. Novita AI docs/pricing URL MUST also be included when Novita data is cited.
- SOURCE DIVERSITY: Sources list must also include at least 2 blog/review/community URLs, not all API docs.
- OUTPUT: Print WordPress-ready HTML to stdout. Start with <h2>. No markdown, no code fences, no markdown tables (use HTML <table> only), no planning text. Do NOT write to files.
ARTICLE_PROMPT_EOF
    fi

    LOGFILE="$JOBS_DIR/logs/${JOBID}.log"
    RESULTFILE="$JOBS_DIR/logs/${JOBID}.result"
    mkdir -p "$JOBS_DIR/logs"

    # Run claude -p in background with timeout protection
    # Read prompt from file to avoid shell quoting issues (context may contain special chars)
    # Both modes use WRITE_RULES + DATA_SOURCE_RULES as system prompt
    SYSTEM_PROMPT="${DATA_SOURCE_RULES}

${WRITE_RULES}"
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
