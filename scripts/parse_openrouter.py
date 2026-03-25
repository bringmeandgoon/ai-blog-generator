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
