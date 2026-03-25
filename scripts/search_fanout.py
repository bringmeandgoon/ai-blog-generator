import json, os

topic = os.environ['FANOUT_TOPIC']
model = os.environ['FANOUT_MODEL']

queries = [
    topic,
    f'site:reddit.com "{model}"',
]
print(json.dumps(queries))
FANOUT_EOF
