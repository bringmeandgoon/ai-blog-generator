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
