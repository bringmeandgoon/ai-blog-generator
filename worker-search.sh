#!/bin/bash
# Worker Search Agent: pre-search data collection, context assembly, review extraction
# Sourced by worker.sh — do NOT run directly.

diagnose_search() {
  local logfile="$1"
  local resultfile="$2"
  local warnings=""

  # Content-based detection: check article output for evidence of research
  # (claude -p --output-format text produces no stderr, so log-based detection is unreliable)
  local article
  article=$(cat "$resultfile" 2>/dev/null)

  if [ -z "$article" ]; then
    warnings="EMPTY_RESULT"
    echo "$warnings"
    return
  fi

  # Count unique external source domains in href links
  local source_domains
  source_domains=$(echo "$article" | grep -oi 'href="https\?://[^"]*"' | grep -v 'href="#' | \
    sed 's|href="https\?://\([^/"]*\).*|\1|' | sort -u | wc -l | tr -d ' ')

  # Check for HuggingFace citations (evidence of model research)
  if ! echo "$article" | grep -qi "huggingface.co"; then
    warnings="${warnings}NO_HF_CITATIONS,"
  fi

  # Check for Novita AI citations (evidence of pricing research)
  if ! echo "$article" | grep -qi "novita.ai"; then
    warnings="${warnings}NO_NOVITA_CITATIONS,"
  fi

  # Check for web source diversity (blogs, reviews, articles beyond HF)
  local non_hf_domains
  non_hf_domains=$(echo "$article" | grep -oi 'href="https\?://[^"]*"' | grep -v 'href="#' | \
    sed 's|href="https\?://\([^/"]*\).*|\1|' | sort -u | grep -v 'huggingface.co\|novita.ai' | wc -l | tr -d ' ')
  if [ "$non_hf_domains" -lt 2 ]; then
    warnings="${warnings}FEW_WEB_SOURCES(${non_hf_domains}),"
  fi

  # Check total source link count
  local link_count
  link_count=$(echo "$article" | grep -oi 'href="https\?://[^"]*"' | grep -v 'href="#' | sort -u | wc -l | tr -d ' ')
  if [ "$link_count" -lt 5 ]; then
    warnings="${warnings}FEW_SOURCE_LINKS(${link_count}),"
  fi

  # Remove trailing comma
  warnings="${warnings%,}"
  echo "$warnings"
}

pre_search() {
  local topic="$1"
  local is_vs="$2"

  source /tmp/blog_search_env.sh
  rm -rf /tmp/blog_data/*

  local topic_encoded=$(echo "$topic" | tr ' ' '+')

  # Strip non-model keywords from topic for HuggingFace search
  # e.g. "minimax m2.5 vram" -> "minimax m2.5"
  strip_keywords() {
    python3 -c "
import re, sys
text = sys.stdin.read().strip()
# Strip tool names (opencode, openclaw, claude code, trae, cursor) and connector words (in, with, for, using)
TOOLS = r'\b(in|with|for|using)\s+(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)\b'
text = re.sub(TOOLS, '', text, flags=re.IGNORECASE)
# Also strip standalone tool names
TOOLS2 = r'\b(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)\b'
text = re.sub(TOOLS2, '', text, flags=re.IGNORECASE)
# Strip provider/platform names with connector words (on/via/through novita, etc.)
# Strip provider/platform names (longer patterns first to avoid partial match)
PROVIDERS = r'\b(on|via|through|from)\s+(novita\s*ai|together\s*ai|novita|fireworks|groq|deepinfra|replicate|anyscale|openrouter)\b'
text = re.sub(PROVIDERS, '', text, flags=re.IGNORECASE)
PROVIDERS2 = r'\b(novita\s*ai|together\s*ai|novita|fireworks|groq|deepinfra|replicate|anyscale|openrouter)\b'
text = re.sub(PROVIDERS2, '', text, flags=re.IGNORECASE)
STOP = r'\b(vram|gpu|benchmark|api[ -]?providers?|providers?|api|how[ -]?to|access|pricing|cost|function[ -]?calling|tool[ -]?use|deploy|run|install|setup|template|instance|hosting|self[ -]?host|inference|serve|serving|requirements?|guide|tutorial|use|using|in|with|for|the|and|on|to|how|get|best|top|new)\b'
text = re.sub(STOP, '', text, flags=re.IGNORECASE)
print(re.sub(r'\s+', ' ', text).strip())
"
  }
  local hf_query=$(echo "$topic" | strip_keywords)

  # Detect Tool Integration articles (topic contains "in opencode/openclaw/claude code/trae/cursor")
  local IS_TOOL_INTEGRATION=0
  local TOOL_NAME=""
  if echo "$topic" | grep -qiE '\b(in|with)\s+(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)\b'; then
    IS_TOOL_INTEGRATION=1
    TOOL_NAME=$(echo "$topic" | python3 -c "
import re, sys
m = re.search(r'\b(?:in|with)\s+(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)', sys.stdin.read(), re.IGNORECASE)
print(m.group(1).strip() if m else '')
")
    echo "[pre-search] Tool Integration detected: model=\"$hf_query\" tool=\"$TOOL_NAME\""
  fi

  # --- Detect article type (used by fan-out, OpenRouter gating, etc.) ---
  local _fanout_type="platform"
  echo "$topic" | grep -qiE 'vram|\bmemory\b' && _fanout_type="vram"
  echo "$topic" | grep -qiE ' vs ' && _fanout_type="vs"
  echo "$topic" | grep -qiE 'api.*(provider|pricing|cost|comparison)' && _fanout_type="api_provider"
  echo "$topic" | grep -qiE 'how.*(access|use)' && _fanout_type="how_to"
  echo "$topic" | grep -qiE '\b(in|with)\s+(opencode|open.code|openclaw|open.claw|claude.code|trae|cursor|continue|codecompanion)\b' && _fanout_type="tool_integration"
  echo "$topic" | grep -qiE '\bon\s+(novita|together|replicate|hugging.?face|fireworks|groq|deepinfra)\b|^deploy\b' && _fanout_type="platform"
  echo "[pre-search] Article type: $_fanout_type"

  # --- parse_hf_repo: select best repo from HF search results ---
  # Prefers exact normalized match over download-count order
  parse_hf_repo() {
    python3 -c "
import sys,json,re
query = sys.argv[1] if len(sys.argv) > 1 else ''
def norm(s):
    return re.sub(r'[^a-z0-9]', '', s.lower())
query_sig = norm(query)
SKIP={'unsloth','lmstudio-community','mlx-community','QuantTrio','RedHatAI','hugging-quants','GadflyII','cyankiwi','DavidAU','TeichAI','lukealonso'}
try:
  models = json.loads(sys.stdin.read())
  valid = []
  for m in models:
    org=m['id'].split('/')[0]
    if org in SKIP: continue
    if any(x in m['id'] for x in ['-GGUF','-AWQ','-FP8','-quantized','-MLX','-NVFP4']): continue
    valid.append(m)
  # Pass 1: exact normalized match (e.g. 'glm47' matches 'GLM-4.7' but NOT 'GLM-4.7-Flash')
  if query_sig:
    for m in valid:
      if norm(m['id'].split('/')[-1]) == query_sig:
        print(m['id']); sys.exit()
  # Pass 2: fallback to first valid by downloads (original behavior)
  if valid:
    print(valid[0]['id'])
except: pass
" "$2" < "$1" 2>/dev/null
  }

  # --- Phase 1: HuggingFace search → parse repo → fetch config/README/detail ---
  if [ "$is_vs" -gt 0 ]; then
    local model_a=$(echo "$topic" | sed -E 's/ [Vv][Ss] .*//')
    local model_b=$(echo "$topic" | sed -E 's/.* [Vv][Ss] //')
    # Also strip non-model keywords from each model name
    model_a=$(echo "$model_a" | strip_keywords)
    model_b=$(echo "$model_b" | strip_keywords)
    echo "[pre-search] VS: \"$model_a\" vs \"$model_b\""
    # Sequential HF requests to avoid rate limiting
    fetch "https://huggingface.co/api/models?search=$(echo "$model_a" | tr ' ' '+')&sort=downloads&direction=-1&limit=15" > /tmp/_hf_search_a.json 2>/dev/null
    fetch "https://huggingface.co/api/models?search=$(echo "$model_b" | tr ' ' '+')&sort=downloads&direction=-1&limit=15" > /tmp/_hf_search_b.json 2>/dev/null
  else
    echo "[pre-search] Topic: \"$topic\" → HF query: \"$hf_query\""
    fetch "https://huggingface.co/api/models?search=$(echo "$hf_query" | tr ' ' '+')&sort=downloads&direction=-1&limit=15" > /tmp/_hf_search_a.json 2>/dev/null
  fi

  # --- Parse best repo → fetch config.json + README.md + detail API (parallel with Tavily etc.) ---
  if [ "$is_vs" -gt 0 ]; then
    local repo_a=$(parse_hf_repo /tmp/_hf_search_a.json "$model_a")
    local repo_b=""
    [ -f /tmp/_hf_search_b.json ] && repo_b=$(parse_hf_repo /tmp/_hf_search_b.json "$model_b")
  else
    local repo_a=$(parse_hf_repo /tmp/_hf_search_a.json "$hf_query")
    local repo_b=""
  fi
  echo "[pre-search] Repo A: ${repo_a:-NOT FOUND}"
  [ "$is_vs" -gt 0 ] && echo "[pre-search] Repo B: ${repo_b:-NOT FOUND}"

  if [ -n "$repo_a" ]; then
    fetch "https://huggingface.co/$repo_a/raw/main/config.json" > /tmp/blog_data/config_a.json 2>/dev/null &
    fetch "https://huggingface.co/$repo_a/raw/main/README.md" > /tmp/blog_data/readme_a.md 2>/dev/null &
    fetch "https://huggingface.co/api/models/$repo_a" > /tmp/blog_data/hf_detail_a.json 2>/dev/null &
  fi
  if [ -n "$repo_b" ]; then
    fetch "https://huggingface.co/$repo_b/raw/main/config.json" > /tmp/blog_data/config_b.json 2>/dev/null &
    fetch "https://huggingface.co/$repo_b/raw/main/README.md" > /tmp/blog_data/readme_b.md 2>/dev/null &
    fetch "https://huggingface.co/api/models/$repo_b" > /tmp/blog_data/hf_detail_b.json 2>/dev/null &
  fi

  # Novita API (public JSON, no auth needed)
  fetch "https://api.novita.ai/v3/openai/models" > /tmp/blog_data/novita.json 2>/dev/null &
  # Novita GPU products (live pricing via cnovita CLI)
  if command -v novita >/dev/null 2>&1 && [ -n "${NOVITA_API_KEY:-}" ]; then
    NOVITA_API_KEY="$NOVITA_API_KEY" novita gpu products --json-output > /tmp/blog_data/novita_gpu_products.json 2>/dev/null &
    echo "[pre-search] Novita GPU products: fetching via CLI..."
  else
    echo "[pre-search] Novita GPU products: CLI not found or NOVITA_API_KEY missing, will use fallback prices"
  fi
  # --- Perplexity Search API: query fan-out (multi-query in one request) ---
  local pplx_key="${PERPLEXITY_API_KEY:-}"
  if [ -n "$pplx_key" ]; then

    # _fanout_type already detected above (before Phase 1)

    # --- Generate search queries from templates (no LLM needed) ---
    local fanout_queries
    fanout_queries=$(FANOUT_TOPIC="$topic" FANOUT_MODEL="$hf_query" python3 "$SCRIPT_DIR/scripts/search_fanout.py")

  # --- HuggingFace: Unsloth GGUF quantization sizes ---
  local _hf_gguf_query
  _hf_gguf_query=$(echo "$hf_query" | tr ' ' '+')
  echo "[pre-search] HF: searching unsloth GGUF for '$hf_query'..."
  fetch "https://huggingface.co/api/models?search=unsloth+${_hf_gguf_query}+GGUF&limit=3" > /tmp/_hf_unsloth_search.json 2>/dev/null
  local _unsloth_repo
    PPLX_QUERIES="$fanout_queries" PPLX_KEY="$pplx_key" python3 "$SCRIPT_DIR/scripts/search_perplexity.py"

  # OpenRouter model lookup (only if fetched above)
  local or_model_id=""
  if [ -f /tmp/blog_data/openrouter_models.json ]; then
  or_model_id=$(python3 -c "
import json, re, sys
query = sys.argv[1]
qn = re.sub(r'[^a-z0-9]', '', query.lower())
try:
    raw = open('/tmp/blog_data/openrouter_models.json').read()
    idx = raw.find('{')
    data = json.loads(raw[idx:]) if idx >= 0 else json.loads(raw)
    # Pass 1: exact suffix match (e.g. 'glm47' == 'glm-4.7')
    for m in data.get('data', []):
        suffix = m['id'].split('/')[-1] if '/' in m['id'] else m['id']
        if re.sub(r'[^a-z0-9]', '', suffix.lower()) == qn:
            print(m['id']); exit()
    # Pass 2: suffix contains query AND is shortest match (avoid v3 matching v3.1-nex-n1)
    candidates = []
    for m in data.get('data', []):
        suffix = m['id'].split('/')[-1] if '/' in m['id'] else m['id']
        sn = re.sub(r'[^a-z0-9]', '', suffix.lower())
        if sn.startswith(qn) or qn in sn:
            candidates.append((len(sn), m['id']))
    if candidates:
        candidates.sort()  # shortest first = most precise
        print(candidates[0][1]); exit()
except: pass
" "$hf_query" 2>/dev/null)

  if [ -n "$or_model_id" ]; then
    echo "[pre-search] OpenRouter model ID: $or_model_id"
    fetch "https://openrouter.ai/api/v1/models/$or_model_id/endpoints" > /tmp/blog_data/openrouter_endpoints.json 2>/dev/null

    # Step 3: Parse providers + auto-select 2-3 similar to Novita's tier
    # (all article types — pricing context is universally useful)
    if [ -s /tmp/blog_data/openrouter_endpoints.json ]; then
      OR_MODEL_ID="$or_model_id" python3 "$SCRIPT_DIR/scripts/parse_openrouter.py"

      # Step 4: For each selected provider, search their official site via Perplexity (API Provider articles only)
      if echo "$topic" | grep -qi 'api\s*provider\|api\s*pricing\|api\s*cost' && [ -n "$PERPLEXITY_API_KEY" ] && [ -f /tmp/blog_data/openrouter_providers.json ]; then
        HF_QUERY="$hf_query" python3 "$SCRIPT_DIR/scripts/search_providers.py"
      fi
    fi
  else
    echo "[pre-search] OpenRouter: model '$hf_query' not found"
  fi
  fi  # end: openrouter_models.json exists

  wait

  # (Phase 2 merged into Phase 1 above — parse_hf_repo + config/README fetch now runs right after HF search)

  wait

  # --- Slim down novita.json: keep only models matching canonical org ---
  if [ -f /tmp/blog_data/novita.json ] && [ -s /tmp/blog_data/novita.json ]; then
    NOVITA_ORG="$hf_query" python3 -c "
import json, re, os, sys
try:
    raw = open('/tmp/blog_data/novita.json').read()
    try: data = json.loads(raw, strict=False)
    except json.JSONDecodeError:
        idx = raw.find('{')
        data = json.loads(raw[idx:], strict=False) if idx >= 0 else {}
    models = data.get('data', [])
    if not models: sys.exit(0)
    org = os.environ.get('NOVITA_ORG','').lower().split()[0] if os.environ.get('NOVITA_ORG') else ''
    if not org: sys.exit(0)
    kept = [m for m in models if org in m.get('id','').lower()]
    data['data'] = kept
    json.dump(data, open('/tmp/blog_data/novita.json','w'), ensure_ascii=False)
    print(f'[pre-search] Novita: {len(models)} -> {len(kept)} models (org={org})')
except Exception as e:
    print(f'[pre-search] Novita filter error: {e}')
" 2>/dev/null
  fi

  # --- Clean up temp files ---
  rm -f /tmp/_hf_search_a.json /tmp/_hf_search_b.json /tmp/_hf_unsloth_search.json /tmp/_hf_unsloth_tree.json

  # --- Phase 3: Generate formatted context using Python ---
  BLOG_TOPIC="$topic" BLOG_MODEL_NAME="$hf_query" BLOG_REPO_A="$repo_a" BLOG_REPO_B="$repo_b" PROJECT_DIR="$SCRIPT_DIR" PPIO_API_KEY="$PPIO_API_KEY" python3 "$SCRIPT_DIR/scripts/search_context.py"
}

# ====== Extract review data for frontend ======
extract_review() {
  local jobid="$1"
  local context_file="$2"

  CONTEXT_FILE="$JOBS_DIR/logs/${jobid}.context" python3 "$SCRIPT_DIR/scripts/search_review.py"

  cp /tmp/blog_data/_review.json "$JOBS_DIR/done/${jobid}.json"
  echo "[worker] [$jobid] Review written ($(wc -c < /tmp/blog_data/_review.json | tr -d ' ') bytes, $(python3 -c "import json; print(len(json.load(open('/tmp/blog_data/_review.json')).get('sources',[])))" 2>/dev/null) sources)"
}

# ====== Additional search (triggered by user feedback) ======
run_search_more() {
  local JOBID="$1" TOPIC="$2" FEEDBACK="$3" REMOVED_URLS="$4"

  echo "[worker] [$JOBID] Phase: additional search — $FEEDBACK"
  source /tmp/blog_search_env.sh

  # Restore saved data
  rm -rf /tmp/blog_data
  cp -r "$JOBS_DIR/logs/${JOBID}_data" /tmp/blog_data 2>/dev/null
  mkdir -p /tmp/blog_data

      if [ -f /tmp/blog_data/_context.txt ]; then
        local _ctx
        _ctx=$(cat /tmp/blog_data/_context.txt | strip_removed_urls "$REMOVED_URLS")
        echo "$_ctx" > /tmp/blog_data/_context.txt
      fi

      OR_MODEL_ID="$or_model_id" python3 "$SCRIPT_DIR/scripts/parse_openrouter.py"
