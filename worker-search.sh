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
    fanout_queries=$(FANOUT_TOPIC="$topic" FANOUT_MODEL="$hf_query" python3 << 'FANOUT_EOF'
import json, os

topic = os.environ['FANOUT_TOPIC']
model = os.environ['FANOUT_MODEL']

queries = [
    topic,
    f'site:reddit.com "{model}"',
]
print(json.dumps(queries))
FANOUT_EOF
    )
    echo "[pre-search] Fan-out: $(echo "$fanout_queries" | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null) queries (type=$_fanout_type)"

    # Save queries for downstream context labeling
    echo "$fanout_queries" > /tmp/blog_data/_fanout_queries.json

    # --- Execute Perplexity multi-query search ---
    echo "[pre-search] Perplexity: searching..."
    PPLX_QUERIES="$fanout_queries" PPLX_KEY="$pplx_key" python3 << 'PPLX_SEARCH_EOF'
import json, os, subprocess, sys

D = '/tmp/blog_data'
queries = json.loads(os.environ.get('PPLX_QUERIES', '[]'))
pplx_key = os.environ.get('PPLX_KEY', '')

if not queries or not pplx_key:
    print("[pplx] No queries or API key", flush=True)
    sys.exit(0)

# Build request body
body = json.dumps({
    'query': queries,
    'max_results': 20,
    'max_tokens': 50000,
    'max_tokens_per_page': 4096,
    'search_recency_filter': 'month',
    'return_language': 'en',
    'search_domain_filter': ['-huggingface.co', '-novita.ai', '-apidog.com'],
})

# Call Perplexity Search API (explicit proxy for reliability)
proxy_port = os.environ.get('https_proxy', '') or os.environ.get('http_proxy', '')
curl_cmd = ['curl', '-sL', '--max-time', '45']
if proxy_port:
    curl_cmd += ['-x', proxy_port]
curl_cmd += [
     '-H', f'Authorization: Bearer {pplx_key}',
     '-H', 'Content-Type: application/json',
     'https://api.perplexity.ai/search',
     '-d', body]
result = subprocess.run(curl_cmd, capture_output=True, text=True, timeout=50)

if result.returncode != 0:
    print(f"[pplx] curl failed: {result.stderr[:200]}", flush=True)
    sys.exit(0)

try:
    data = json.loads(result.stdout)
    results = data.get('results', [])
    print(f"[pplx] {len(results)} results returned", flush=True)

    # Save as unified format compatible with downstream code
    # Map Perplexity format to Tavily-like format for backward compat
    converted = {
        'results': [
            {
                'title': r.get('title', ''),
                'url': r.get('url', ''),
                'content': r.get('snippet', ''),
                'date': r.get('date', ''),
            }
            for r in results
        ]
    }
    json.dump(converted, open(f"{D}/tavily_fanout_0.json", 'w'), ensure_ascii=False)

    # Log each result
    for i, r in enumerate(results):
        print(f"  [{i}] {r.get('title','')[:60]} | {r.get('url','')}", flush=True)
except Exception as e:
    print(f"[pplx] parse error: {e}", flush=True)
    # Save raw response for debugging
    open(f"{D}/pplx_raw.txt", 'w').write(result.stdout[:5000])
PPLX_SEARCH_EOF

  else
    echo "[pre-search] No PERPLEXITY_API_KEY, skipping web search"
  fi

  # --- HuggingFace: Unsloth GGUF quantization sizes ---
  local _hf_gguf_query
  _hf_gguf_query=$(echo "$hf_query" | tr ' ' '+')
  echo "[pre-search] HF: searching unsloth GGUF for '$hf_query'..."
  fetch "https://huggingface.co/api/models?search=unsloth+${_hf_gguf_query}+GGUF&limit=3" > /tmp/_hf_unsloth_search.json 2>/dev/null
  local _unsloth_repo
  _unsloth_repo=$(python3 -c "
import json, sys
try:
    raw = open('/tmp/_hf_unsloth_search.json').read()
    idx = raw.find('[')
    data = json.loads(raw[idx:]) if idx >= 0 else json.loads(raw)
    for m in data:
        mid = m.get('id','')
        if mid.startswith('unsloth/') and 'GGUF' in mid:
            print(mid); break
except: pass
" 2>/dev/null)

  if [ -n "$_unsloth_repo" ]; then
    echo "[pre-search] Unsloth GGUF: $_unsloth_repo"
    fetch "https://huggingface.co/api/models/$_unsloth_repo/tree/main" > /tmp/_hf_unsloth_tree.json 2>/dev/null
    # Fetch key quant sizes in parallel
    local _gguf_quants
    _gguf_quants=$(python3 -c "
import json
raw = open('/tmp/_hf_unsloth_tree.json').read()
idx = raw.find('[')
tree = json.loads(raw[idx:]) if idx >= 0 else json.loads(raw)
dirs = [d['path'] for d in tree if d['type'] == 'directory']
priority = ['BF16', 'Q8_0', 'Q6_K', 'Q4_K_M', 'Q3_K_M', 'Q2_K', 'IQ4_XS', 'UD-IQ2_XXS', 'UD-IQ1_S']
selected = [p for p in priority if p in dirs]
if not selected:
    selected = dirs[:6]
for s in selected[:8]: print(s)
" 2>/dev/null)
    echo "$_gguf_quants" | while IFS= read -r _q; do
      [ -n "$_q" ] && fetch "https://huggingface.co/api/models/$_unsloth_repo/tree/main/$_q" > "/tmp/blog_data/hf_gguf_${_q}.json" 2>/dev/null &
    done
  else
    echo "[pre-search] Unsloth GGUF: no repo found for '$hf_query'"
  fi

  # --- HuggingFace Inference: provider throughput + pricing ---
  # No pipeline_tag filter — models may be text-generation, image-text-to-text, etc.
  # No inference=warm filter — some models have providers but don't show with warm filter.
  echo "[pre-search] HF Inference: searching providers for '$hf_query'..."
  fetch "https://huggingface.co/api/models?search=${_hf_gguf_query}&limit=5&expand%5B%5D=inferenceProviderMapping" > /tmp/blog_data/hf_inference.json 2>/dev/null
  local _hf_provider_count
  _hf_provider_count=$(python3 -c "
import json
try:
    raw = open('/tmp/blog_data/hf_inference.json').read()
    idx = raw.find('[')
    data = json.loads(raw[idx:]) if idx >= 0 else json.loads(raw)
    count = 0
    for m in data[:1]:
        for item in m.get('inferenceProviderMapping', []):
            if item.get('status') == 'live':
                count += 1
    print(count)
except: print(0)
" 2>/dev/null)
  echo "[pre-search] HF Inference: ${_hf_provider_count:-0} live providers"

  # --- OpenRouter: only fetch for api_provider articles ---
  if [ "$_fanout_type" = "api_provider" ]; then
    echo "[pre-search] OpenRouter: fetching for api_provider article..."
    fetch "https://openrouter.ai/api/v1/models" > /tmp/blog_data/openrouter_models.json 2>/dev/null
  else
    echo "[pre-search] Non-api_provider article, skipping OpenRouter"
  fi

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
      OR_MODEL_ID="$or_model_id" python3 << 'ORPARSE'
import json, os

api_path = "/tmp/blog_data/openrouter_endpoints.json"
out_path = "/tmp/blog_data/openrouter_providers.json"

if not os.path.exists(api_path) or os.path.getsize(api_path) < 100:
    json.dump({"error": "API fetch failed", "all": [], "selected": []}, open(out_path, "w"))
    exit()

try:
    raw_text = open(api_path).read()
    idx = raw_text.find('{')
    raw = json.loads(raw_text[idx:]) if idx > 0 else json.loads(raw_text)
    endpoints = raw.get('data', {}).get('endpoints', [])
except:
    json.dump({"error": "JSON parse failed", "all": [], "selected": []}, open(out_path, "w"))
    exit()

model_id = os.environ.get('OR_MODEL_ID', '')
model_org = model_id.split('/')[0] if '/' in model_id else ''

all_providers = []
for ep in endpoints:
    pricing = ep.get('pricing', {})
    name = ep.get('provider_name', '?')
    tag = ep.get('tag', '')
    slug = tag.split('/')[0] if '/' in tag else ''
    all_providers.append({
        "name": name,
        "slug": slug,
        "quantization": ep.get('quantization', 'unknown'),
        "context_length": ep.get('context_length'),
        "max_completion_tokens": ep.get('max_completion_tokens'),
        "input_price": round(float(pricing.get('prompt', 0)) * 1_000_000, 2),
        "output_price": round(float(pricing.get('completion', 0)) * 1_000_000, 2),
        "cache_read_price": round(float(pricing.get('input_cache_read', 0) or 0) * 1_000_000, 2),
        "latency_ms": ep.get('latency_last_30m'),
        "throughput_tps": ep.get('throughput_last_30m'),
        "uptime_pct": ep.get('uptime_last_30m'),
    })

# --- Selection: pick 2-3 providers with different strengths vs Novita ---
EXCLUDE = {'NovitaAI', 'Novita AI', 'Novita'}

candidates = []
for p in all_providers:
    if p['name'] in EXCLUDE:
        continue
    if p['slug'] and model_org and p['slug'] == model_org:
        continue
    candidates.append(p)

selected = []
selected_names = set()

# Pick best on each dimension (different ecological niche from Novita)
dimensions = [
    ('cheapest',   lambda c: c['output_price'] if c['output_price'] > 0 else 9999),
    ('lowest_latency', lambda c: c['latency_ms'] if c.get('latency_ms') else 9999999),
    ('highest_throughput', lambda c: -(c['throughput_tps'] if c.get('throughput_tps') else 0)),
]
for dim_name, key_fn in dimensions:
    if len(selected) >= 3:
        break
    ranked = sorted(candidates, key=key_fn)
    for c in ranked:
        if c['name'] not in selected_names:
            c['_selected_reason'] = dim_name
            selected.append(c)
            selected_names.add(c['name'])
            break

# If fewer than 3, fill from remaining candidates
if len(selected) < 3:
    for c in candidates:
        if c['name'] not in selected_names:
            c['_selected_reason'] = 'additional'
            selected.append(c)
            selected_names.add(c['name'])
            if len(selected) >= 3:
                break

result = {
    "model_id": model_id,
    "all": all_providers,
    "selected": [s['name'] for s in selected],
    "selected_details": selected,
}
json.dump(result, open(out_path, "w"), indent=2)
sel_info = [f"{s['name']}({s.get('_selected_reason','?')})" for s in selected]
print(f"[or-parse] {len(all_providers)} providers found, {len(selected)} selected: {sel_info}")
ORPARSE

      # Step 4: For each selected provider, search their official site via Perplexity (API Provider articles only)
      if echo "$topic" | grep -qi 'api\s*provider\|api\s*pricing\|api\s*cost' && [ -n "$PERPLEXITY_API_KEY" ] && [ -f /tmp/blog_data/openrouter_providers.json ]; then
        HF_QUERY="$hf_query" python3 << 'PROV_SEARCH_EOF'
import json, os, subprocess, sys

D = "/tmp/blog_data"
pplx_key = os.environ.get('PERPLEXITY_API_KEY', '')
curl_bin = os.environ.get('CURL', 'curl')
hf_query = os.environ.get('HF_QUERY', '')

PROVIDER_DOMAINS = {
    'Together': 'together.ai', 'Together AI': 'together.ai',
    'Groq': 'groq.com', 'DeepInfra': 'deepinfra.com',
    'Parasail': 'parasail.io', 'SambaNova': 'sambanova.ai',
    'AtlasCloud': 'atlascloud.ai',
}

_raw = open(f'{D}/openrouter_providers.json').read()
_idx = _raw.find('{')
data = json.loads(_raw[_idx:]) if _idx > 0 else json.loads(_raw)
selected = data.get('selected', [])
if not selected:
    sys.exit(0)

# Build one multi-query request for all providers
queries = []
for name in selected:
    domain = PROVIDER_DOMAINS.get(name, '')
    if domain:
        queries.append(f"site:{domain} {hf_query} API")
    else:
        queries.append(f"{name} {hf_query} API inference")
queries = queries[:5]  # Perplexity max 5 queries

body = json.dumps({
    'queries': queries,
    'max_results': 5,
    'max_tokens': 30000,
    'max_tokens_per_page': 4096,
    'search_recency_filter': 'month',
})

proxy_port2 = os.environ.get('https_proxy', '') or os.environ.get('http_proxy', '')
curl_cmd2 = [curl_bin, '-sL', '--max-time', '30']
if proxy_port2:
    curl_cmd2 += ['-x', proxy_port2]
curl_cmd2 += [
     '-H', f'Authorization: Bearer {pplx_key}',
     '-H', 'Content-Type: application/json',
     '-X', 'POST', 'https://api.perplexity.ai/search',
     '-d', body]
result = subprocess.run(curl_cmd2, capture_output=True, text=True, timeout=35)

try:
    resp = json.loads(result.stdout)
    results = resp.get('results', [])
    converted = {
        'results': [
            {'title': r.get('title',''), 'url': r.get('url',''), 'content': r.get('snippet',''), 'date': r.get('date','')}
            for r in results
        ]
    }
    json.dump(converted, open(f"{D}/tavily_provider_0.json", 'w'), ensure_ascii=False)
    print(f"[pre-search] Perplexity provider search: {len(results)} results for {len(queries)} queries", flush=True)
except Exception as e:
    print(f"[pre-search] Provider search failed: {e}", flush=True)
PROV_SEARCH_EOF
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
  BLOG_TOPIC="$topic" BLOG_MODEL_NAME="$hf_query" BLOG_REPO_A="$repo_a" BLOG_REPO_B="$repo_b" PROJECT_DIR="$SCRIPT_DIR" PPIO_API_KEY="$PPIO_API_KEY" python3 << 'PYEOF'
import json, os, re, html as html_lib
from urllib.parse import unquote

D = "/tmp/blog_data"
ctx = []

def safe_json_load(path):
    """Load JSON from file, handling prefix lines and control characters."""
    with open(path) as f:
        raw = f.read()
    # Try direct parse first (strict=False tolerates control chars in strings)
    try:
        return json.loads(raw, strict=False)
    except json.JSONDecodeError:
        pass
    # Strip prefix lines until we find JSON start
    for start_char in ['{', '[']:
        idx = raw.find(start_char)
        if idx > 0:
            try:
                return json.loads(raw[idx:], strict=False)
            except json.JSONDecodeError:
                pass
    raise json.JSONDecodeError("No valid JSON found", raw[:100], 0)

ARCH_KEYS = ['model_type','hidden_size','num_hidden_layers','num_attention_heads',
  'num_key_value_heads','intermediate_size','vocab_size','max_position_embeddings',
  'n_routed_experts','n_shared_experts','num_experts_per_tok','num_local_experts',
  'moe_intermediate_size','sliding_window','torch_dtype']

def fmt_params(n):
    """Format parameter count to human-readable string like '229B' or '7.8B'."""
    if not n: return ''
    if n >= 1e12: return f"{n/1e12:.1f}T"
    if n >= 1e9: return f"{n/1e9:.1f}B" if n % 1e9 else f"{int(n/1e9)}B"
    if n >= 1e6: return f"{n/1e6:.0f}M"
    return str(n)

def fmt_model(label, config_path, readme_path, detail_path='', preferred_repo=''):
    """Format one model's HF data."""
    repo = preferred_repo or None
    total_params = ''
    total_params_raw = 0
    def _get_param_count(st_data):
        """Extract parameter count from safetensors metadata, excluding I32 routing indices."""
        if not st_data: return 0
        params = st_data.get('parameters', {})
        if params:
            weight_sum = sum(v for k, v in params.items() if not k.startswith('I'))
            if weight_sum > 0:
                return weight_sum
        return st_data.get('total', 0) or 0

    # Get param count from detail API
    if detail_path:
        try:
            detail = safe_json_load(detail_path)
            total_params_raw = _get_param_count(detail.get('safetensors',{}))
            if not repo:
                repo = detail.get('id', '')
        except: pass
    # README param extraction — preferred for MoE models where safetensors counts may differ
    # from advertised total (e.g. compressed weights vs logical MoE params)
    _readme_params = 0
    if os.path.exists(readme_path):
        try:
            with open(readme_path) as f:
                rtxt = f.read(5000).lower()
            import re as _re
            # Match patterns like "230B", "230 billion", "1T", "1 trillion"
            # Check trillion first (higher priority), then billion
            for pat, multiplier in [
                (r'total\s+param[^|]*?\|\s*(\d+(?:\.\d+)?)\s*t\b', 1e12),      # table: "| total parameters | 1T |"
                (r'(\d+(?:\.\d+)?)\s*(?:t|trillion)\s*(?:total\s+)?param', 1e12),
                (r'total\s+(?:of\s+)?(\d+(?:\.\d+)?)\s*(?:t|trillion)', 1e12),
                (r'(\d+(?:\.\d+)?)\s*(?:b|billion)\s*(?:total\s+)?param', 1e9),
                (r'total\s+param[^|]*?\|\s*(\d+(?:\.\d+)?)\s*b\b', 1e9),       # table: "| total parameters | 230B |"
                (r'total\s+(?:of\s+)?(\d+(?:\.\d+)?)\s*(?:b|billion)', 1e9),
                (r'(\d+(?:\.\d+)?)\s*(?:b|billion)\s*(?:total)', 1e9),
                (r'(\d+(?:\.\d+)?)\s*b\b.*?(?:moe|mixture|expert)', 1e9),
            ]:
                match = _re.search(pat, rtxt)
                if match:
                    val = float(match.group(1))
                    computed = int(val * multiplier)
                    if 1e9 < computed < 1e13:  # sanity: 1B-10T range
                        _readme_params = computed
                        break
        except: pass
    # Prefer README param count (reflects official/marketed total) over safetensors
    # safetensors may count compressed weights or exclude MoE routing tables
    if _readme_params:
        total_params_raw = _readme_params
    total_params = fmt_params(total_params_raw)

    ctx.append(f"--- {label} ---")
    if not repo:
        ctx.append("HuggingFace repo: NOT FOUND (model may use a different name on HF)")
        ctx.append("")
        return

    ctx.append(f"HuggingFace repo: {repo}")
    ctx.append(f"URL: https://huggingface.co/{repo}")
    if total_params:
        ctx.append(f"Total parameters: {total_params}")
    # Extract activated parameters for MoE models from README
    if os.path.exists(readme_path):
        try:
            with open(readme_path) as f:
                _rtxt_act = f.read(5000).lower()
            import re as _re
            for _ap in [
                r'activated\s+param[^|]*?\|\s*(\d+(?:\.\d+)?)\s*([bt])\b',   # table: "| Activated Parameters | 32B |"
                r'(\d+(?:\.\d+)?)\s*([bt])\s*(?:activated|active)\s*param',   # inline: "32B activated parameters"
            ]:
                _am = _re.search(_ap, _rtxt_act)
                if _am:
                    _av = float(_am.group(1))
                    _au = 'T' if _am.group(2) == 't' else 'B'
                    ctx.append(f"Activated parameters: {_av:.0f}{_au} (per token)")
                    break
        except: pass
    ctx.append("")

    # config.json — search top level AND nested sub-configs (text_config, llm_config, etc.)
    if os.path.exists(config_path) and os.path.getsize(config_path) > 10:
        try:
            config = safe_json_load(config_path)
            ctx.append("Architecture (config.json):")
            found_keys = {}
            # Search top level first, then nested dicts (text_config, llm_config, language_config, etc.)
            search_layers = [('', config)]
            for key, val in config.items():
                if isinstance(val, dict) and len(val) > 3:
                    search_layers.append((f'{key}.', val))
            for prefix, layer in search_layers:
                for k in ARCH_KEYS:
                    if k in layer and k not in found_keys:
                        found_keys[k] = (prefix, layer[k])
            for k in ARCH_KEYS:
                if k in found_keys:
                    prefix, val = found_keys[k]
                    ctx.append(f"  {k}: {val}" + (f"  (from {prefix[:-1]})" if prefix else ""))
            # Also extract architectures field for model type detection
            if 'architectures' in config:
                ctx.append(f"  architectures: {config['architectures']}")
            # Detect multimodal from config structure
            has_vision = any(k in config for k in ['vision_config', 'visual_config', 'vt_hidden_size',
                                                     'media_placeholder_token_id', 'image_token_id'])
            for sub in config.values():
                if isinstance(sub, dict):
                    has_vision = has_vision or any(k in sub for k in ['vision_config', 'visual_config', 'vt_hidden_size'])
            if has_vision:
                ctx.append("  multimodal: YES (vision config detected)")
            ctx.append("")
        except:
            ctx.append("config.json: parse error")
            ctx.append("")

    # README.md — extract structured benchmark analysis + brief intro
    if os.path.exists(readme_path) and os.path.getsize(readme_path) > 10:
        with open(readme_path) as f:
            readme_raw = f.read(60000)

        # --- Parse HTML <table> elements BEFORE stripping HTML ---
        html_tables = []  # [(section_header, [rows])]  rows = [cells]
        # Find section headers near tables
        def _find_header_before(text, pos):
            chunk = text[:pos]
            m = list(re.finditer(r'^#{1,4}\s+(.+)', chunk, re.M))
            return m[-1].group(1).strip() if m else ''

        for tm in re.finditer(r'<table[\s\S]*?</table>', readme_raw, re.I):
            thtml = tm.group()
            sec = _find_header_before(readme_raw, tm.start())
            rows = []
            # Track rowspan carry-overs: {col_index: (value, remaining_rows)}
            rowspan_carry = {}
            # Parse <th> and <td> rows
            for tr_m in re.finditer(r'<tr[^>]*>([\s\S]*?)</tr>', thtml, re.I):
                tr_html = tr_m.group(1)
                # Skip colspan rows (category headers like "Reasoning & Knowledge")
                if 'colspan' in tr_html and '<strong>' in tr_html:
                    continue
                cells = []
                cell_idx = 0
                cell_matches = list(re.finditer(r'<t([hd])([^>]*)>([\s\S]*?)</t\1>', tr_html, re.I))
                ci = 0  # index into cell_matches
                num_cols = len(rows[0]) if rows else 99
                while cell_idx < num_cols and ci <= len(cell_matches):
                    # Insert carried-over rowspan value at this position
                    if cell_idx in rowspan_carry:
                        val, remaining = rowspan_carry[cell_idx]
                        cells.append(val)
                        if remaining <= 1:
                            del rowspan_carry[cell_idx]
                        else:
                            rowspan_carry[cell_idx] = (val, remaining - 1)
                        cell_idx += 1
                        continue
                    # Process next actual cell from HTML
                    if ci >= len(cell_matches):
                        break
                    cm = cell_matches[ci]
                    attrs = cm.group(2)
                    cell = cm.group(3)
                    ci += 1
                    # Parse rowspan
                    rs_m = re.search(r'rowspan=["\']?(\d+)', attrs)
                    # Strip HTML tags, keep text
                    cell = re.sub(r'<br\s*/?>', ' ', cell)
                    cell = re.sub(r'<sup>[†*\d]+</sup>', '', cell)
                    cell = re.sub(r'<[^>]+>', '', cell)
                    cell = re.sub(r'\s+', ' ', cell).strip()
                    cells.append(cell)
                    if rs_m:
                        rs = int(rs_m.group(1))
                        if rs > 1:
                            rowspan_carry[cell_idx] = (cell, rs - 1)
                    cell_idx += 1
                if cells and len(cells) >= 2:
                    rows.append(cells)
            if rows:
                html_tables.append((sec, rows))

        # Strip SVG/HTML noise (after HTML table extraction)
        readme = readme_raw
        readme = re.sub(r'<svg[\s\S]*?</svg>', '', readme)
        readme = re.sub(r'<table[\s\S]*?</table>', '', readme)  # already parsed above
        readme = re.sub(r'<div[\s\S]*?</div>', '', readme)
        readme = re.sub(r'<p[\s\S]*?</p>', '', readme)
        readme = re.sub(r'<img[^>]*>', '', readme)
        readme = re.sub(r'\n{3,}', '\n\n', readme)

        # --- Brief intro (first meaningful paragraph, max 500 chars) ---
        # Also check raw README before HTML stripping for intros inside tags
        intro = ''
        for src in [readme_raw[:5000], readme[:3000]]:
            for para in re.split(r'\n\n+', src):
                p = para.strip()
                # Skip HTML-heavy lines
                if p.startswith(('<','#','|','---','```')): continue
                p_clean = re.sub(r'<[^>]+>', '', p).strip()
                if len(p_clean) > 80:
                    intro = p_clean[:500]
                    break
            if intro: break

        # --- Parse all markdown tables into structured data ---
        lines = readme.split('\n')
        tables = []      # [(header, rows)]
        cur_header = ''
        cur_rows = []
        for line in lines:
            s = line.strip()
            if s.startswith('#'):
                if cur_rows:
                    tables.append((cur_header, cur_rows))
                    cur_rows = []
                cur_header = s.lstrip('#').strip()
            elif '|' in s and s.startswith('|'):
                cells = [c.strip() for c in s.split('|')[1:-1]]
                if cells and not all(set(c) <= {'-',':',' '} for c in cells):
                    cur_rows.append(cells)
        if cur_rows:
            tables.append((cur_header, cur_rows))

        # Merge HTML tables into the same structure
        tables.extend(html_tables)

        # --- Analyze benchmarks: find where target model ranks #1 or top-2 ---
        # Target model name detection from repo name
        model_short = repo.split('/')[-1].lower().replace('-',' ')
        strengths = []   # [(benchmark, score, rank, competitors_summary)]
        all_benchmarks = []

        for header, rows in tables:
            if len(rows) < 3: continue  # need header + separator eaten + data
            col_names = rows[0]
            data_rows = rows[1:]

            # Find which column is the target model
            target_col = -1
            repo_name = repo.split('/')[-1]
            repo_norm = re.sub(r'[^a-z0-9]', '', repo_name.lower())
            # (repo_parts removed — Pass 3 now uses token-based matching)

            # Pass 1: exact normalized match (e.g. "Qwen3-30B-A3B" == "Qwen3-30B-A3B")
            for ci, cn in enumerate(col_names):
                if ci == 0: continue
                cn_norm = re.sub(r'[^a-z0-9]', '', cn.lower())
                if cn_norm == repo_norm:
                    target_col = ci
                    break

            # Pass 2: column starts with repo name (e.g. "Qwen3-30B-A3B-Thinking-2507")
            if target_col < 1:
                for ci, cn in enumerate(col_names):
                    if ci == 0: continue
                    cn_norm = re.sub(r'[^a-z0-9]', '', cn.lower())
                    if cn_norm.startswith(repo_norm):
                        target_col = ci
                        break

            # Pass 2.5: repo starts with column (repo has extra suffix, e.g. repo "GLM-5-0520" matches column "GLM-5")
            if target_col < 1:
                for ci, cn in enumerate(col_names):
                    if ci == 0: continue
                    cn_norm = re.sub(r'[^a-z0-9]', '', cn.lower())
                    if len(cn_norm) >= 4 and repo_norm.startswith(cn_norm):
                        target_col = ci
                        break

            # Pass 3: TOKEN-BASED matching (split on spaces/hyphens/underscores, NOT dots)
            # "GLM-5" tokens: {"glm","5"}. Column "GLM-4.5" tokens: {"glm","4.5"} → "5" not in set → no match
            # This prevents "5" substring-matching inside "4.5" or "15"
            if target_col < 1:
                repo_tokens = set(p for p in re.split(r'[\s\-_]+', repo_name.lower()) if p)
                if len(repo_tokens) >= 2:
                    for ci, cn in enumerate(col_names):
                        if ci == 0: continue
                        cn_tokens = set(p for p in re.split(r'[\s\-_]+', cn.lower()) if p)
                        if repo_tokens.issubset(cn_tokens):
                            target_col = ci
                            break

            if target_col < 1: continue  # col 0 is benchmark name

            for dr in data_rows:
                if len(dr) <= target_col: continue
                bench_name = dr[0].strip().rstrip('*')
                if not bench_name or len(bench_name) < 2: continue

                # Parse scores for all models
                scores = {}
                for ci in range(1, len(col_names)):
                    if ci >= len(dr): continue
                    val = dr[ci].strip().rstrip('*').replace(',','')
                    # Handle "xx.x" or "xx.x%"
                    m = re.search(r'(\d+\.?\d*)', val)
                    if m:
                        scores[col_names[ci].strip()] = float(m.group(1))

                target_name = col_names[target_col].strip()
                if target_name not in scores: continue
                target_score = scores[target_name]

                # Rank (higher is better for most benchmarks)
                sorted_models = sorted(scores.items(), key=lambda x: -x[1])
                rank = next((i+1 for i,(n,s) in enumerate(sorted_models) if n == target_name), 0)

                # Top 3 competitors for context
                top3 = [f"{n}: {s}" for n,s in sorted_models[:4] if n != target_name][:3]

                all_benchmarks.append({
                    'section': header,
                    'bench': bench_name,
                    'score': target_score,
                    'rank': rank,
                    'total': len(scores),
                    'top3': top3,
                    'scores': dict(scores)
                })

                if rank <= 2:
                    strengths.append({
                        'section': header,
                        'bench': bench_name,
                        'score': target_score,
                        'rank': rank,
                        'total': len(scores),
                        'top3': top3
                    })

        # --- Build concise output ---
        ctx.append("README.md (structured benchmark analysis — do NOT just rewrite this):")
        if intro:
            ctx.append(f"Intro: {intro}")
            ctx.append("")

        if all_benchmarks:
            # Summary paragraph
            total = len(all_benchmarks)
            top1 = sum(1 for b in all_benchmarks if b['rank'] == 1)
            top2 = sum(1 for b in all_benchmarks if b['rank'] <= 2)
            top3 = sum(1 for b in all_benchmarks if b['rank'] <= 3)
            sections = list(dict.fromkeys(s['section'] for s in strengths))
            ctx.append(f"Summary: Across {total} benchmarks, ranks #1 in {top1}, top-2 in {top2}, top-3 in {top3}.")
            if sections:
                ctx.append(f"Strongest areas: {', '.join(sections[:5])}")
            ctx.append("")

            # Full table with ALL models (so article can cite any model's score)
            all_model_names = []
            _seen_models = set()
            for b in all_benchmarks:
                for name in b['scores']:
                    if name not in _seen_models:
                        all_model_names.append(name)
                        _seen_models.add(name)

            ctx.append("ALL BENCHMARKS (all models — use these scores directly, do NOT write 'Not disclosed' if a score exists here):")
            ctx.append("| Benchmark | " + " | ".join(all_model_names) + " |")
            ctx.append("|---" + "|---" * len(all_model_names) + "|")
            for b in all_benchmarks:
                row = f"| {b['bench']}"
                for name in all_model_names:
                    val = b['scores'].get(name)
                    row += f" | {val:g}" if val is not None else " | -"
                ctx.append(row + " |")
            ctx.append("")

        # --- Extract inline text scores: "X% in/on BenchmarkName" ---
        # Catches benchmarks only shown in images or prose (e.g. MiniMax M2.5 SWE/Terminal Bench)
        text_scores = []
        seen_bench_names = {re.sub(r'[^a-z0-9]', '', b['bench'].lower()) for b in all_benchmarks}
        for m in re.finditer(
            r'(\d+\.?\d*)\s*%\s+(?:in|on)\s+([\w][\w\s\-\.\/]+?)(?=\s*[,\.\(]|\s+and\b|\s*$)',
            readme_raw[:15000], re.IGNORECASE | re.MULTILINE
        ):
            score = float(m.group(1))
            bench = m.group(2).strip().rstrip('.')
            bench_norm = re.sub(r'[^a-z0-9]', '', bench.lower())
            if 2 < len(bench) < 60 and score > 0 and bench_norm not in seen_bench_names:
                text_scores.append((bench, score))
                seen_bench_names.add(bench_norm)
        if text_scores:
            ctx.append("SCORES MENTIONED IN TEXT (model's own numbers, no competitor comparison):")
            for bench, score in text_scores:
                ctx.append(f"  {bench}: {score}%")
            ctx.append("")

        # --- Extract key README sections (Features, Deployment, Quantization, etc.) ---
        # These are important for article content beyond just benchmarks
        key_sections = []
        section_pattern = re.compile(r'^#{1,4}\s+(.+)', re.M)
        section_starts = [(m.start(), m.group(1).strip()) for m in section_pattern.finditer(readme)]
        # Keywords that indicate important sections to preserve
        keep_keywords = ['feature', 'deploy', 'quantiz', 'usage', 'install', 'setup', 'getting started',
                         'inference', 'requirement', 'hardware', 'key ', 'highlight', 'what\'s new',
                         'architecture', 'model summary', 'native int']
        for i, (start, title) in enumerate(section_starts):
            title_low = title.lower()
            if any(kw in title_low for kw in keep_keywords):
                end = section_starts[i+1][0] if i+1 < len(section_starts) else len(readme)
                section_text = readme[start:end].strip()
                # Cap each section at 800 chars
                if len(section_text) > 800:
                    section_text = section_text[:800] + '...'
                key_sections.append(section_text)
        if key_sections:
            ctx.append("KEY SECTIONS FROM README:")
            ctx.append('\n\n'.join(key_sections))
            ctx.append("")

        if not all_benchmarks and not strengths:
            # Fallback: raw first 2K + raw tables
            ctx.append(readme[:1500])
            ctx.append("")


# ===== Build context =====
canonical_name = os.environ.get('BLOG_MODEL_NAME', '').strip()
ctx.append("=== PRE-FETCHED RESEARCH DATA ===")
if canonical_name:
    ctx.append(f"")
    ctx.append(f"╔══════════════════════════════════════════════════════════╗")
    ctx.append(f"║  CANONICAL MODEL NAME: {canonical_name}")
    ctx.append(f"║  USE THIS EXACT STRING everywhere in the article.")
    ctx.append(f"║  NEVER shorten, abbreviate, or drop version numbers.")
    ctx.append(f"║  e.g. \"{canonical_name}\" — not \"{canonical_name.split()[0]}\" alone")
    ctx.append(f"╚══════════════════════════════════════════════════════════╝")
    ctx.append(f"")
ctx.append("This data was fetched automatically. Use it directly for your article.")
ctx.append("You may run additional Bash curl if you need more specific data.")
ctx.append("")

# Model data
repo_a_env = os.environ.get('BLOG_REPO_A', '')
repo_b_env = os.environ.get('BLOG_REPO_B', '')
if repo_a_env or os.path.exists(f"{D}/hf_detail_a.json"):
    label_a = "Model A" if (repo_b_env or os.path.exists(f"{D}/hf_detail_b.json")) else "Model"
    fmt_model(label_a, f"{D}/config_a.json", f"{D}/readme_a.md", f"{D}/hf_detail_a.json", repo_a_env)
if repo_b_env or os.path.exists(f"{D}/hf_detail_b.json"):
    fmt_model("Model B", f"{D}/config_b.json", f"{D}/readme_b.md", f"{D}/hf_detail_b.json", repo_b_env)

# Web research — Perplexity search snippets direct into context

# --- Web Research: Perplexity search snippets (direct, no LLM filter needed) ---
from urllib.parse import urlparse as _urlparse
_seen_urls = set()
_seen_domains = {}  # domain -> count (max 2 per domain to avoid duplicate content)
_web_parts = []
for _fn in sorted(os.listdir(D)):
    if _fn.startswith('tavily_') and _fn.endswith('.json') and '_queries' not in _fn:
        _path = f"{D}/{_fn}"
        if not os.path.exists(_path) or os.path.getsize(_path) < 50:
            continue
        try:
            _data = safe_json_load(_path)
            for r in _data.get('results', []):
                url = r.get('url', '')
                if url in _seen_urls: continue
                _seen_urls.add(url)
                # Domain-level dedup: max 2 results per domain
                _domain = _urlparse(url).netloc.replace('www.', '')
                _seen_domains[_domain] = _seen_domains.get(_domain, 0) + 1
                if _seen_domains[_domain] > 2: continue
                # Skip non-English results (titles in CJK, Cyrillic, or with common non-EN URL patterns)
                title = r.get('title', '')
                _path_lower = url.lower()
                if any(p in _path_lower for p in ['/nl/', '/it/', '/de/', '/fr/', '/es/', '/pt/', '/ja/', '/ko/', '/zh/', '/ru/']):
                    continue
                content = r.get('content', '')
                if content:
                    _web_parts.append(f"[{title}] {url}")
                    _web_parts.append(content[:1500])
        except: pass

if _web_parts:
    ctx.append("--- Web Research (Perplexity Search) ---")
    ctx.append(f"⚠ CITATION VERSION CHECK: canonical model = \"{canonical_name}\"")
    ctx.append("  Before citing ANY source, verify it discusses THIS EXACT version.")
    ctx.append("NOTE: Use web research for practical insights (tips, gotchas, use cases) only.")
    ctx.append("Do NOT re-use specs/benchmarks from here — those come from HuggingFace ONLY.")
    ctx.append("")
    ctx.append('\n'.join(_web_parts))
    ctx.append("")
    import sys as _sys; print(f"[pre-search] Web research: {len(_seen_urls)} sources, {len(chr(10).join(_web_parts)):,} chars", file=_sys.stderr, flush=True)

# OpenRouter / HF Inference data: Write Agent reads JSON files directly via DATA_MAP
# (openrouter_providers.json, hf_inference.json, openrouter_endpoints.json)

# Novita AI pricing (from /v3/openai/models API)
# FILTER to only show relevant models — prevent version confusion (e.g. V3 vs V3.2)
novita_path = f"{D}/novita.json"
if os.path.exists(novita_path) and os.path.getsize(novita_path) > 50:
    try:
        novita_data = safe_json_load(novita_path)
        models_list = novita_data.get('data', [])
        if models_list:
            ctx.append("--- Novita AI Pricing (USD per 1M tokens) ---")
            ctx.append("Source: https://novita.ai/pricing (via API)")

            # Use canonical model name (stripped of keywords) for matching
            # Normalize: "M2.5" -> "m2 5", "V3.2" -> "v3 2" (dots/hyphens -> spaces)
            def norm(s):
                return re.sub(r'[./-]', ' ', s.lower()).strip()
            cn_norm = norm(canonical_name)  # e.g. "deepseek v3 2", "minimax m2 5"
            cn_words = cn_norm.split()  # e.g. ["deepseek", "v3", "2"]
            # org = first word (e.g. "deepseek", "minimax", "qwen")
            cn_org = cn_words[0] if cn_words else ''

            # Find exact match and same-org models
            exact_candidates = []  # [(model_id, inp, out, word_count)]
            same_org = []
            for m in models_list:
                mid_norm = norm(m['id'])  # "deepseek/deepseek-v3.2" -> "deepseek deepseek v3 2"
                inp = m.get('input_token_price_per_m', 0) / 10000.0
                out = m.get('output_token_price_per_m', 0) / 10000.0
                # Exact match: all canonical words appear in normalized model ID
                # Try word-boundary match first, then substring fallback (for "qwen3" matching "qwen 3")
                mid_norm_words = mid_norm.split()
                is_word_match = cn_words and all(w in mid_norm_words for w in cn_words)
                is_substr_match = False
                if not is_word_match and cn_words:
                    # Fallback: join canonical words and check as substring (e.g. "qwen3" contains "qwen"+"3")
                    cn_joined = ''.join(cn_words)  # "qwen3", "deepseekv32"
                    mid_joined = mid_norm.replace(' ', '')  # "deepseekdeepseekv32"
                    is_substr_match = cn_joined in mid_joined
                if is_word_match or is_substr_match:
                    # match_quality: 0=word match (best), 1=substring match (fallback)
                    mq = 0 if is_word_match else 1
                    exact_candidates.append((m['id'], inp, out, len(mid_norm_words), mq))
                # Same org: for price comparison context (e.g. other deepseek models)
                if cn_org and cn_org in mid_norm.split():
                    same_org.append((m['id'], inp, out))
            # Pick the most precise match: prefer word-match over substring, then fewest words
            # e.g. "glm 4 7" matches "glm-4.7" (word, 5w) and "glm-4.7-flash" (word, 6w)
            # → prefer "glm-4.7" (fewer words = more precise)
            # e.g. "glm 4 6" matches "glm-4.6" (word, 5w) and "glm-4.6v" (substr, 5w)
            # → prefer "glm-4.6" (word match > substring match)
            exact_match = None
            if exact_candidates:
                exact_candidates.sort(key=lambda x: (x[4], x[3]))  # match_quality asc, word_count asc
                exact_match = (exact_candidates[0][0], exact_candidates[0][1], exact_candidates[0][2])

            if exact_match:
                ctx.append(f"  >>> USE THIS PRICE for \"{canonical_name}\": {exact_match[0]}: ${exact_match[1]:.2f}/1M in, ${exact_match[2]:.2f}/1M out <<<")
                ctx.append(f"  (Do NOT use prices from other versions — they are listed below for reference only)")
            else:
                ctx.append(f"  WARNING: No exact Novita API match for \"{canonical_name}\". Check if model name differs on Novita.")

            # Show same-org models for context (but clearly labeled as OTHER versions)
            if same_org:
                ctx.append(f"  Same family (reference only, do NOT use these prices for {canonical_name}):")
                for mid, inp, out in same_org:
                    marker = " ◄ THIS ONE" if exact_match and mid == exact_match[0] else ""
                    ctx.append(f"    {mid}: ${inp:.2f}/1M in, ${out:.2f}/1M out{marker}")
            ctx.append("")
    except: pass

gpu_path = f"{D}/novita_gpu_products.json"
_gpu_written = False
if os.path.exists(gpu_path) and os.path.getsize(gpu_path) > 50:
    try:
        gpu_data = safe_json_load(gpu_path)
        products = gpu_data if isinstance(gpu_data, list) else gpu_data.get('products', gpu_data.get('data', []))
        if products:
            ctx.append("--- Novita AI GPU Instance Pricing (https://novita.ai/gpu-instance) ---")
            ctx.append("Source: novita.ai live API via cnovita CLI — use these REAL prices, do NOT make up GPU costs")
            for p in products:
                name = p.get('gpu_type') or p.get('name') or p.get('product_name', '')
                vram = p.get('gpu_memory') or p.get('vram') or p.get('memory', '')
                if vram:
                    vram = f"{vram}GB VRAM" if str(vram).isdigit() else str(vram)
                od = p.get('on_demand_price') or p.get('price') or p.get('hourly_price')
                spot = p.get('spot_price') or p.get('preemptible_price')
                gpu_num = p.get('gpu_num', 1)
                label = f"  {name}" + (f" {vram}" if vram else "") + (f" (x{gpu_num})" if gpu_num and int(gpu_num) > 1 else "")
                pricing = ""
                if od:
                    pricing += f"On-Demand ${float(od):.2f}/hr"
                if spot:
                    pricing += f" | Spot ${float(spot):.2f}/hr"
                if pricing:
                    ctx.append(f"{label}: {pricing}")
            ctx.append("IMPORTANT: When writing about GPU deployment costs, use these Novita prices as reference.")
            ctx.append("  For multi-GPU setups, calculate from single-GPU price × count.")
            ctx.append("")
            _gpu_written = True
    except Exception as _e:
        pass

if not _gpu_written:
    ctx.append("--- Novita AI GPU Instance Pricing (https://novita.ai/gpu-instance) ---")
    ctx.append("Source: novita.ai/gpu-instance — use these REAL prices, do NOT make up GPU costs")
    ctx.append("  RTX 5090 32GB VRAM: On-Demand $0.63/hr (1x), $5.04/hr (8x) | Spot $0.32/hr (1x), $2.56/hr (8x)")
    ctx.append("  RTX 4090 24GB VRAM: On-Demand $0.67/hr (1x), $5.36/hr (8x)")
    ctx.append("  H100 SXM 80GB VRAM: On-Demand $1.45/hr (1x), $11.60/hr (8x) | Spot $0.73/hr (1x), $5.84/hr (8x)")
    ctx.append("  Storage: Container Disk 60GB free then $0.005/GB/day | Volume Disk $0.005/GB/day | Network Volume $0.002/GB/day")
    ctx.append("IMPORTANT: When writing about GPU deployment costs, use these Novita prices as reference.")
    ctx.append("  For multi-GPU setups, calculate from single-GPU price × count (e.g., 4×H100 = $5.80/hr on-demand).")
    ctx.append("")

# Unsloth GGUF quantization sizes (from HuggingFace API)
import glob as _glob
gguf_files = sorted(_glob.glob(f"{D}/hf_gguf_*.json"))
if gguf_files:
    sizes = []
    for gf in gguf_files:
        quant = os.path.basename(gf).replace('hf_gguf_', '').replace('.json', '')
        try:
            files = safe_json_load(gf)
            total = sum(f.get('size', 0) for f in files if f.get('type') == 'file')
            if total > 0:
                sizes.append((quant, total / 1e9))
        except:
            pass
    if sizes:
        ctx.append("--- Unsloth GGUF Quantization Sizes (HuggingFace) ---")
        ctx.append("Source: HuggingFace unsloth GGUF repo — file size ≈ minimum VRAM for full model loading")
        ctx.append("Add 1-4 GB overhead for KV cache depending on context length and batch size.")
        # Detect MoE: check if config has n_routed_experts
        _is_moe = False
        try:
            _cfg = safe_json_load(f"{D}/config_a.json")
            for _layer in [_cfg] + [v for v in _cfg.values() if isinstance(v, dict)]:
                if 'n_routed_experts' in _layer or 'num_local_experts' in _layer:
                    _is_moe = True; break
        except: pass
        if _is_moe:
            ctx.append("⚠ MoE MODEL: File sizes show FULL model VRAM. With expert offloading (llama.cpp, KTransformers),")
            ctx.append("  actual VRAM can be much lower since only activated experts need GPU memory. Check inference engine docs.")
        ctx.append("Quantization | File Size (≈ VRAM for full load)")
        for quant, gb in sorted(sizes, key=lambda x: x[1]):
            ctx.append(f"  {quant}: {gb:.1f} GB")
        ctx.append("")

# Novita AI selling points are now covered by skill.txt in RAG index

# RAG: retrieve relevant Novita integration guides (replaces old keyword-based doc search)
# Supplements the static data above with specific how-to docs when topic matches
try:
    import subprocess as _sp
    _rag_script = os.path.join(os.environ.get('PROJECT_DIR', '.'), 'scripts', 'rag-retrieve.py')
    _topic_env = os.environ.get('BLOG_TOPIC', '')
    _model_env = os.environ.get('BLOG_MODEL_NAME', '')
    if os.path.exists(_rag_script) and _topic_env:
        # Strip model name from topic to avoid RAG matching wrong docs
        # e.g. "how to access kimi k2.5" → "how to access" (prevents matching "Kling 2.5")
        _rag_query = _topic_env
        if _model_env:
            _keyword_part = _topic_env.lower().replace(_model_env.lower(), '').strip()
            if len(_keyword_part) < 5:
                _rag_query = _topic_env  # fallback to full topic
            else:
                # Map article types to specific RAG queries for better doc matching
                _type_queries = {
                    'access': 'novita ai claude code cursor continue setup integration llm api',
                    'use in': 'novita ai claude code cursor continue setup integration',
                    'api provider': 'novita ai llm api pricing openai compatible',
                    'vram': 'novita ai gpu instance pricing serverless deployment',
                }
                _rag_query = f"novita ai {_keyword_part}"
                for _kw, _q in _type_queries.items():
                    if _kw in _keyword_part:
                        _rag_query = _q
                        break
        _rag = _sp.run(
            ['python3', _rag_script, _rag_query],
            capture_output=True, text=True, timeout=30
        )
        if _rag.returncode == 0 and _rag.stdout.strip():
            ctx.append("--- Novita AI Integration Guide (from docs, use for setup/usage steps) ---")
            ctx.append(_rag.stdout.strip())
            ctx.append("")
except Exception as e:
    ctx.append(f"(RAG retrieval failed: {e})")

# --- Completeness check: flag missing data blocks so claude -p knows what to search for ---
_ctx_joined = '\n'.join(ctx)
_missing = []
if 'HuggingFace repo: NOT FOUND' in _ctx_joined or 'HuggingFace repo:' not in _ctx_joined:
    _missing.append("HuggingFace repo (model not found on HF — verify model name)")
else:
    if 'Architecture (config.json):' not in _ctx_joined:
        _missing.append("config.json architecture specs")
    if 'Total parameters:' not in _ctx_joined:
        _missing.append("parameter count")
    # Check README content was loaded (intro or benchmarks or key sections)
    _has_readme = any(x in _ctx_joined for x in ['ALL BENCHMARKS:', 'KEY SECTIONS FROM README:', 'README intro:'])
    if not _has_readme:
        _missing.append("README content (no benchmarks, intro, or key sections extracted)")
if '--- Unsloth GGUF' not in _ctx_joined:
    _missing.append("Unsloth GGUF quantization sizes")
if '--- Novita AI Pricing' not in _ctx_joined:
    _missing.append("Novita AI API pricing")
if '--- Web Research' not in _ctx_joined:
    _missing.append("Web research / external sources")

if _missing:
    ctx.append("")
    ctx.append("⚠ DATA COMPLETENESS WARNING — the following data was NOT found during pre-search:")
    for m in _missing:
        ctx.append(f"  • MISSING: {m}")
    ctx.append("You MUST use `source /tmp/blog_search_env.sh && fetch \"URL\"` to find this data yourself.")
    ctx.append("Do NOT guess or make up data for missing items.")

ctx.append("=== END PRE-FETCHED DATA ===")

with open(f"{D}/_context.txt", 'w') as f:
    f.write('\n'.join(ctx))

total = len('\n'.join(ctx))
import sys as _sys2; print(f"[pre-search] Context: {total} chars, files: {len([x for x in os.listdir(D) if not x.startswith('_')])}", file=_sys2.stderr)
PYEOF
}

# ====== Extract review data for frontend ======
extract_review() {
  local jobid="$1"
  local context_file="$2"

  python3 << 'REVIEW_EOF' > /tmp/blog_data/_review.json
import json, os, glob, re
from urllib.parse import urlparse

D = "/tmp/blog_data"
sources = []
seen_urls = set()
seen_domains = {}  # domain -> count

def safe_json_load(path):
    raw = open(path).read()
    try: return json.loads(raw, strict=False)
    except json.JSONDecodeError: pass
    for ch in ['{', '[']:
        idx = raw.find(ch)
        if idx > 0:
            try: return json.loads(raw[idx:], strict=False)
            except: pass
    raise json.JSONDecodeError("No valid JSON", raw[:100], 0)

# Extract sources from Perplexity search results
for fname in sorted(glob.glob(f"{D}/tavily_*.json")):
    try:
        data = safe_json_load(fname)
        category = os.path.basename(fname).replace('.json','').replace('tavily_','')
        for r in data.get('results', []):
            url = r.get('url', '')
            if url and url not in seen_urls:
                seen_urls.add(url)
                # Domain-level dedup: max 2 per domain
                domain = urlparse(url).netloc.replace('www.', '')
                seen_domains[domain] = seen_domains.get(domain, 0) + 1
                if seen_domains[domain] > 2: continue
                # Skip non-English URLs (path patterns, .cn TLD, non-ASCII)
                if any(p in url.lower() for p in ['/nl/', '/it/', '/de/', '/fr/', '/es/', '/pt/', '/ja/', '/ko/', '/zh/', '/ru/']):
                    continue
                if domain.endswith('.cn') or domain.endswith('.com.cn'):
                    continue
                if not url.isascii():
                    continue
                sources.append({
                    'title': r.get('title', ''),
                    'url': url,
                    'snippet': (r.get('content', '') or '')[:200],
                    'category': category,
                })
    except:
        pass

# Extract HF repo info
hf_repo = ''
hf_params = ''
for name in ['hf_detail_a.json']:
    path = f"{D}/{name}"
    if not os.path.exists(path):
        continue
    try:
        data = safe_json_load(path)
        if isinstance(data, dict) and 'id' in data:
            hf_repo = data['id']
            st = data.get('safetensors', {})
            total = st.get('total', 0)
            if total:
                if total >= 1e9:
                    hf_params = f"{total/1e9:.1f}B"
                elif total >= 1e6:
                    hf_params = f"{total/1e6:.0f}M"
            break
    except:
        pass
# Add HF as source
if hf_repo:
    sources.insert(0, {
        'title': f'HuggingFace: {hf_repo}',
        'url': f'https://huggingface.co/{hf_repo}',
        'snippet': f'Model card and config (params: {hf_params})',
        'category': 'huggingface',
    })


# Read context
context = ''
ctx_path = f"{D}/_context.txt"
if os.path.exists(ctx_path):
    context = open(ctx_path, errors='replace').read()

# Extract Novita pricing match from context
novita_match = ''
m = re.search(r'>>> USE THIS PRICE[^:]*:\s*(.*?)<<<', context)
if m:
    novita_match = m.group(1).strip()

# OpenRouter providers count
provider_count = 0
or_path = f"{D}/openrouter_providers.json"
if os.path.exists(or_path):
    try:
        or_data = safe_json_load(or_path)
        provider_count = len(or_data.get('all', []))
    except:
        pass

result = {
    'status': 'review',
    'contextFile': os.environ.get('CONTEXT_FILE', ''),
    'sources': sources,
    'summary': {
        'hfRepo': hf_repo,
        'hfParams': hf_params,
        'novitaMatch': novita_match,
        'webSourceCount': len([s for s in sources if s['category'] != 'huggingface']),
        'providerCount': provider_count,
        'contextSize': len(context),
    },
    'rawContext': context,
}
json.dump(result, open(f"{D}/_review.json", 'w'), ensure_ascii=False)
REVIEW_EOF

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

      SEARCH_TOPIC="$TOPIC" SEARCH_FEEDBACK="$FEEDBACK" PPIO_API_KEY="$PPIO_API_KEY" PERPLEXITY_API_KEY="$PERPLEXITY_API_KEY" CURL_BIN="$CURL" python3 << 'SEARCH_MORE_EOF'
import json, os, re, subprocess, urllib.request as ur

D = "/tmp/blog_data"
topic = os.environ.get('SEARCH_TOPIC', '')
feedback = os.environ.get('SEARCH_FEEDBACK', '')
ppio_key = os.environ.get('PPIO_API_KEY', '')
pplx_key = os.environ.get('PERPLEXITY_API_KEY', '')
curl_bin = os.environ.get('CURL_BIN', 'curl')

# Strip keywords to get canonical model name (same logic as pre_search)
def strip_kw(text):
    text = re.sub(r'\b(in|with|for|using)\s+(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)\b', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\b(opencode|open\s*code|openclaw|open\s*claw|claude\s*code|trae|cursor)\b', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\b(on|via|through|from)\s+(novita\s*ai|together\s*ai|novita|fireworks|groq|deepinfra|replicate|anyscale|openrouter)\b', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\b(novita\s*ai|together\s*ai|novita|fireworks|groq|deepinfra|replicate|anyscale|openrouter)\b', '', text, flags=re.IGNORECASE)
    text = re.sub(r'\b(vram|gpu|benchmark|api[ -]?providers?|providers?|api|how[ -]?to|access|pricing|cost|function[ -]?calling|tool[ -]?use|deploy|run|install|setup|template|instance|hosting|self[ -]?host|inference|serve|serving|requirements?|guide|tutorial|use|using|in|with|for|the|and|on|to|how|get|best|top|new)\b', '', text, flags=re.IGNORECASE)
    return re.sub(r'\s+', ' ', text).strip()

model_name = strip_kw(topic)
print(f"[search_more] Model: '{model_name}', Feedback: '{feedback}'", flush=True)

# --- Step 1: MiniMax M2.5 generates search queries ---
queries = []
if ppio_key:
    prompt = f"""You are a search query optimizer. Given a model name and user feedback, generate 1-3 concise search queries.

MODEL NAME: {model_name}
ORIGINAL TOPIC: {topic}
USER FEEDBACK: {feedback}

RULES:
- ALWAYS include the model name "{model_name}" in every query
- Keep each query concise (under 12 words), like searching on Google
- If user says data is wrong, search for authoritative sources (HuggingFace, official docs)
- If user wants more sources, search for the specific type (Reddit, blogs, benchmarks, etc.)
- Output ONLY a JSON array of query strings, nothing else
- Max 3 queries

Example output: ["{model_name} VRAM requirements", "{model_name} deployment tips reddit"]"""

    payload = json.dumps({
        'model': 'minimax/minimax-m2.5',
        'messages': [{'role': 'user', 'content': prompt}],
        'max_tokens': 300,
        'temperature': 0.3,
    }).encode()
    req = ur.Request(
        'https://api.ppinfra.com/v3/openai/chat/completions',
        data=payload,
        headers={'Authorization': f'Bearer {ppio_key}', 'Content-Type': 'application/json'},
    )
    try:
        opener = ur.build_opener(ur.ProxyHandler({}))
        with opener.open(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
        content = data['choices'][0]['message']['content']
        if '<think>' in content:
            content = re.sub(r'<think>[\s\S]*?</think>', '', content).strip()
        m = re.search(r'\[.*\]', content, re.DOTALL)
        if m:
            queries = json.loads(m.group())
            print(f"[search_more] MiniMax queries: {queries}", flush=True)
    except Exception as e:
        print(f"[search_more] MiniMax query gen failed ({e}), using fallback", flush=True)

# Fallback: simple concatenation
if not queries:
    queries = [f"{model_name} {feedback}"]
    print(f"[search_more] Fallback queries: {queries}", flush=True)

# --- Step 2: Perplexity multi-query search ---
results = []
if pplx_key:
    body = json.dumps({
        'queries': queries[:5],
        'max_results': 10,
        'max_tokens': 30000,
        'max_tokens_per_page': 4096,
        'search_recency_filter': 'month',
    })
    try:
        proxy_sm = os.environ.get('https_proxy', '') or os.environ.get('http_proxy', '')
        curl_sm = [curl_bin, '-sL', '--max-time', '30']
        if proxy_sm:
            curl_sm += ['-x', proxy_sm]
        curl_sm += [
             '-H', f'Authorization: Bearer {pplx_key}',
             '-H', 'Content-Type: application/json',
             '-X', 'POST', 'https://api.perplexity.ai/search',
             '-d', body]
        result = subprocess.run(curl_sm, capture_output=True, text=True, timeout=35)
        resp = json.loads(result.stdout)
        results = resp.get('results', [])
        # Save as backward-compatible format
        converted = {
            'results': [
                {'title': r.get('title',''), 'url': r.get('url',''), 'content': r.get('snippet',''), 'date': r.get('date','')}
                for r in results
            ]
        }
        json.dump(converted, open(f"{D}/tavily_additional_0.json", 'w'), ensure_ascii=False)
        print(f"[search_more] Perplexity: {len(results)} results", flush=True)
    except Exception as e:
        print(f"[search_more] Perplexity search failed: {e}", flush=True)

# --- Step 3: Append snippets directly to context (no LLM filter) ---
snippet_parts = []
for r in results:
    title = r.get('title', '')
    url = r.get('url', '')
    snippet = (r.get('snippet', '') or '')[:1500]
    if snippet:
        snippet_parts.append(f"[{title}] {url}")
        snippet_parts.append(snippet)
additional_text = '\n'.join(snippet_parts)

# --- Step 4: Append to context ---
ctx = open(f"{D}/_context.txt", errors='replace').read()
ctx = ctx.replace("=== END PRE-FETCHED DATA ===", "")
ctx += f"\n--- Additional Search (user request: {feedback}) ---\n"
ctx += additional_text
ctx += "\n\n=== END PRE-FETCHED DATA ===\n"
open(f"{D}/_context.txt", 'w').write(ctx)
print(f"[search_more] Context updated ({len(ctx)} chars total)", flush=True)
SEARCH_MORE_EOF

  # Save updated data
  cp -r /tmp/blog_data/* "$JOBS_DIR/logs/${JOBID}_data/" 2>/dev/null
  cp /tmp/blog_data/_context.txt "$JOBS_DIR/logs/${JOBID}.context"

  # Write updated review
  CONTEXT_FILE="$JOBS_DIR/logs/${JOBID}.context" extract_review "$JOBID" "$JOBS_DIR/logs/${JOBID}.context"
}

# ====== Initial search for new jobs ======
run_initial_search() {
  local JOBID="$1" TOPIC="$2" IS_VS="$3"

  echo "[worker] [$JOBID] Running pre-search..."
  pre_search "$TOPIC" "$IS_VS"
  PRE_CONTEXT=$(cat /tmp/blog_data/_context.txt 2>/dev/null)
  echo "[worker] [$JOBID] Pre-search done ($(echo "$PRE_CONTEXT" | wc -c | tr -d ' ') bytes)"

  # Save data for later phases
  mkdir -p "$JOBS_DIR/logs/${JOBID}_data"
  cp -r /tmp/blog_data/* "$JOBS_DIR/logs/${JOBID}_data/" 2>/dev/null
  cp /tmp/blog_data/_context.txt "$JOBS_DIR/logs/${JOBID}.context"

  # Write review for frontend
  CONTEXT_FILE="$JOBS_DIR/logs/${JOBID}.context" extract_review "$JOBID" "$JOBS_DIR/logs/${JOBID}.context"
}
