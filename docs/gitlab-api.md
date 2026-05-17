# Accessing freedesktop GitLab issues

Project: `drm/amd` at gitlab.freedesktop.org. Numeric ID: `4522`.

Issue vs work_item: newer issues use the URL `/work_items/NNNN`, older ones use
`/issues/NNNN`. Both refer to the same numeric IID and the API endpoints are
identical.

## Pitfalls (read first)

- REST `/issues/NNNN/notes` returns **401 even for public issues** on this
  GitLab instance. Use the GraphQL API instead for notes/comments.
- REST `/issues/NNNN` returns an empty `description` for newer "work items".
  Use GraphQL as fallback when the body is empty.
- GraphQL requires a session cookie (Anubis-protected). REST search and REST
  body-fetch work without auth.
- Run GraphQL queries **one at a time** — the server rate-limits and may
  return 429 / temporary blocks on bursts.

## Cookies (for GraphQL)

Obtain from Firefox DevTools → Network → any request to gitlab.freedesktop.org
→ copy the `Cookie` header. Required cookies:

- `_gitlab_session`
- `techaro.lol-anubis-auth`
- `techaro.lol-anubis-cookie-verification`

## REST: fetch issue body (no auth)

```bash
ISSUE=5274
curl -s "https://gitlab.freedesktop.org/api/v4/projects/4522/issues/$ISSUE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('Title:', d['title'])
print('State:', d['state'])
print(d['description'][:3000])
"
```

## REST: search issues by keyword (no auth, state=all for open+closed)

```bash
TERM="MES firmware"
curl -s "https://gitlab.freedesktop.org/api/v4/projects/4522/issues?search=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$TERM")&state=all&per_page=20" \
  -H "User-Agent: Mozilla/5.0" | python3 -c "
import json,sys
for i in json.load(sys.stdin):
    state='OPEN' if i['state']=='opened' else 'CLOSED'
    print(f\"[{state}] #{i['iid']} — {i['title']} ({i['created_at'][:10]})\")
"
```

Useful search terms for this project: `MES firmware`, `mes_v12`, `uni_mes`,
`CP_MES`, `MES null`, `DS_GFXCLK`, `GFXOFF ring timeout`.

## GraphQL: full issue + all notes (cookie required)

Use this when REST returns an empty body, or to fetch the body and all
comments in one request.

```bash
COOKIE="_gitlab_session=...; techaro.lol-anubis-cookie-verification=...; techaro.lol-anubis-auth=..."
ISSUE=5298
curl -s "https://gitlab.freedesktop.org/api/graphql" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:150.0) Gecko/20100101 Firefox/150.0" \
  -H "Content-Type: application/json" \
  -H "Cookie: $COOKIE" \
  -d "{\"query\":\"{ project(fullPath: \\\"drm/amd\\\") { issue(iid: \\\"$ISSUE\\\") { title state description notes { nodes { author { username } createdAt body } } } } }\"}" \
  | python3 -c "
import json,sys
issue=json.load(sys.stdin)['data']['project']['issue']
print('Title:', issue['title'])
print(issue['description'][:3000])
print()
for n in issue['notes']['nodes']:
    if not n.get('body') or len(n['body']) < 10: continue
    print(f\"[{n['author']['username']} @ {n['createdAt'][:10]}]\")
    print(n['body'][:1000])
    print()
"
```

## Extracting data from a HAR file

If the user provides a HAR captured while browsing an issue page, GraphQL
responses inside the HAR contain the full comment data — no cookie needed.

```bash
python3 -c "
import json
with open('path/to/file.har') as f:
    har = json.load(f)
for e in har['log']['entries']:
    if 'graphql' not in e['request']['url']: continue
    text = e['response']['content'].get('text', '')
    if not text or len(text) < 5000: continue
    data = json.loads(text)
    def find_bodies(obj, d=0):
        if d > 10: return
        if isinstance(obj, dict):
            if 'body' in obj and isinstance(obj['body'], str) and len(obj['body']) > 20:
                name = obj.get('author', {}).get('username', '?') if isinstance(obj.get('author'), dict) else '?'
                print(f'[{name}]:', obj['body'][:800])
            for v in obj.values(): find_bodies(v, d+1)
        elif isinstance(obj, list):
            for i in obj: find_bodies(i, d+1)
    find_bodies(data)
"
```
