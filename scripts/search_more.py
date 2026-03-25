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
