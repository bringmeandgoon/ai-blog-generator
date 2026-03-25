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
