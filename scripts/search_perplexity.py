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
