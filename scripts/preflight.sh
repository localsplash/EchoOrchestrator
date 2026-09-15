#!/usr/bin/env bash
#
# Preflight checks for one Echo deployment.
#
#   scripts/preflight.sh X.TLD
#
# Every public URL derives from PARENT_DOMAIN, so one argument is enough to
# check a whole environment. Exits non-zero if any check fails, so it can gate
# a deploy.
#
# Optional, for the settings check:
#   NOCODB_BASE_URL=... NOCODB_API_TOKEN=... scripts/preflight.sh X.TLD
#
# The webhook checks deliberately send NO credentials. A correctly configured
# host rejects them. If one ever answers 2xx this script fails loudly, because
# that is the exact hole that was open before: behind Nginx Proxy Manager every
# request arrived from the proxy's own address, which falls inside the
# 172.16.0.0/12 entry of trustedCIDR, so the peer check passed for every caller
# and an unauthenticated POST could write fabricated inbound messages.

set -uo pipefail

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  echo "usage: $0 X.TLD" >&2
  exit 64
fi

APP="echo.${DOMAIN}"
HOOK="webhook.echo.${DOMAIN}"
RETIRED="media.echo.${DOMAIN}"

pass=0; fail=0; warn=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
hmm()  { printf '  \033[33mWARN\033[0m  %s\n' "$1"; warn=$((warn+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null; }
body() { curl -sS --max-time 15 "$@" 2>/dev/null || true; }

printf '\033[1mEcho preflight — %s\033[0m\n' "$DOMAIN"

# ── DNS ──────────────────────────────────────────────────────────────────────
head_ "DNS"
for h in "$APP" "$HOOK"; do
  if getent hosts "$h" >/dev/null 2>&1 || host "$h" >/dev/null 2>&1; then
    ok "$h resolves"
  else
    no "$h does not resolve"
  fi
done
if getent hosts "$RETIRED" >/dev/null 2>&1 || host "$RETIRED" >/dev/null 2>&1; then
  hmm "$RETIRED still resolves — EchoMedia should have no public hostname"
else
  ok "$RETIRED absent, as intended"
fi

# ── TLS ──────────────────────────────────────────────────────────────────────
# A certificate that does not cover the name reaches a carrier as a failed
# handshake, which it reports as a delivery failure — far harder to trace back
# to the edge than a served error would be.
head_ "TLS"
for h in "$APP" "$HOOK"; do
  san=$(echo | timeout 15 openssl s_client -connect "${h}:443" -servername "$h" 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null)
  if [ -z "$san" ]; then
    no "$h — no certificate retrieved"
  elif grep -qiE "DNS:${h//./\\.}(,|$| )" <<<"$san"; then
    ok "$h — certificate covers this name"
  else
    no "$h — certificate does NOT cover this name (SAN: $(tr -d '\n' <<<"$san" | sed 's/  */ /g'))"
  fi
done

# ── Application ──────────────────────────────────────────────────────────────
head_ "Application — https://${APP}"
c=$(code "https://${APP}/healthz")
case "$c" in
  200) ok "/healthz 200" ;;
  000) no "/healthz unreachable" ;;
  *)   no "/healthz returned $c" ;;
esac

c=$(code "https://${APP}/readyz")
case "$c" in
  200) ok "/readyz 200" ;;
  503) no "/readyz 503 — database or settings unavailable" ;;
  000) no "/readyz unreachable" ;;
  *)   no "/readyz returned $c" ;;
esac

cfg=$(body "https://${APP}/config.js")
if [ -z "$cfg" ]; then
  no "/config.js returned nothing"
elif grep -q '"MEDIA_BASE_URL":"/media"' <<<"$cfg"; then
  ok '/config.js serves media at /media'
elif grep -q '"MEDIA_BASE_URL":"/api/media"' <<<"$cfg"; then
  no '/config.js still advertises /api/media — EchoWeb predates the rename'
else
  no "/config.js advertises an external media origin: $(grep -o '"MEDIA_BASE_URL":"[^"]*"' <<<"$cfg" || echo '(key absent)')"
fi

# The private origin must never reach the browser. Only meaningful if
# something was actually served — an empty body must not pass this vacuously.
if [ -z "$cfg" ]; then
  hmm "media-origin leak check skipped — /config.js served nothing"
elif grep -qE 'echo-media|https?://[^"]*media\.' <<<"$cfg"; then
  no "/config.js leaks a media origin to the browser"
else
  ok "/config.js exposes no private media origin"
fi

# ── Carrier webhooks ─────────────────────────────────────────────────────────
head_ "Carrier webhooks — https://${HOOK}"
HOOKS="/webhooks/bandwidth/inbound /webhooks/bandwidth/status /webhooks/tychron/sms /webhooks/tychron/mms"
for path in $HOOKS; do
  c=$(code -X POST -H 'Content-Type: application/json' --data '{}' "https://${HOOK}${path}")
  case "$c" in
    401|403) ok "${path} rejects unauthenticated POST ($c)" ;;
    2??)     no "${path} ACCEPTED an unauthenticated POST ($c) — anyone can write inbound messages" ;;
    404)     no "${path} not found ($c) — wrong host, or EchoService is not behind it" ;;
    000)     no "${path} unreachable" ;;
    *)       hmm "${path} answered $c (expected 401/403)" ;;
  esac
done

# 2 MB of valid JSON. nginx enforces client_max_body_size before the request
# reaches the application, so a 413 here means the edge would reject an
# ordinary Tychron MMS — which Tychron then redelivers indefinitely, because it
# treats any non-2xx as temporary.
head_ "Webhook body limit"
payload=$(mktemp); trap 'rm -f "$payload"' EXIT
{ printf '{"pad":"'; head -c 2000000 /dev/zero | tr '\0' 'a'; printf '"}'; } > "$payload"
c=$(code -X POST -H 'Content-Type: application/json' --data-binary "@${payload}" \
         "https://${HOOK}/webhooks/tychron/mms")
case "$c" in
  413)     no "2 MB body rejected 413 — raise client_max_body_size to 10m" ;;
  401|403) ok "2 MB body accepted by the edge, then rejected on auth ($c)" ;;
  2??)     no "2 MB unauthenticated POST ACCEPTED ($c) — body limit fine, auth is not" ;;
  000)     no "unreachable" ;;
  *)       hmm "answered $c" ;;
esac

# ── PlatformConfig ───────────────────────────────────────────────────────────
head_ "PlatformConfig"
if [ -z "${NOCODB_BASE_URL:-}" ] || [ -z "${NOCODB_API_TOKEN:-}" ]; then
  hmm "skipped — set NOCODB_BASE_URL and NOCODB_API_TOKEN to check settings rows"
else
  bases=$(body -H "xc-token: ${NOCODB_API_TOKEN}" "${NOCODB_BASE_URL}/api/v2/meta/bases")
  base_id=$(python3 - "$bases" <<'PY' 2>/dev/null
import json,sys
try: rows=[b for b in json.loads(sys.argv[1]).get('list',[]) if b.get('title')=='PlatformConfig']
except Exception: rows=[]
print(rows[0]['id'] if len(rows)==1 else '')
PY
)
  if [ -z "$base_id" ]; then
    no "expected exactly one NocoDB base named PlatformConfig"
  else
    ok "PlatformConfig base found"
    tables=$(body -H "xc-token: ${NOCODB_API_TOKEN}" "${NOCODB_BASE_URL}/api/v2/meta/bases/${base_id}/tables")
    tid=$(python3 - "$tables" <<'PY' 2>/dev/null
import json,sys
try: rows=[t for t in json.loads(sys.argv[1]).get('list',[]) if t.get('title')=='cfg_tbl_Setting']
except Exception: rows=[]
print(rows[0]['id'] if len(rows)==1 else '')
PY
)
    if [ -z "$tid" ]; then
      no "expected one cfg_tbl_Setting table in PlatformConfig"
    else
      recs=$(body -H "xc-token: ${NOCODB_API_TOKEN}" "${NOCODB_BASE_URL}/api/v2/tables/${tid}/records?limit=200")
      for key in PARENT_DOMAIN APP_BASE_URL IDENTITY_BASE_URL; do
        found=$(python3 - "$recs" "$key" <<'PY' 2>/dev/null
import json,sys
try: rows=json.loads(sys.argv[1]).get('list',[])
except Exception: rows=[]
print('yes' if any(r.get('settingKey')==sys.argv[2] and (r.get('settingValue') or '').strip()
                   for r in rows) else 'no')
PY
)
        [ "$found" = "yes" ] && ok "$key set" || no "$key missing or blank"
      done
      # These moved to process environment; a row is ignored and will mislead.
      for key in MEDIA_BASE_URL ECHO_SERVICE_BASE_URL MEDIA_INTERNAL_BASE_URL; do
        found=$(python3 - "$recs" "$key" <<'PY' 2>/dev/null
import json,sys
try: rows=json.loads(sys.argv[1]).get('list',[])
except Exception: rows=[]
print('yes' if any(r.get('settingKey')==sys.argv[2] for r in rows) else 'no')
PY
)
        [ "$found" = "yes" ] \
          && hmm "$key has a row but is no longer read — delete it to avoid confusion" \
          || ok "$key correctly absent"
      done
    fi
  fi
fi

printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ] || exit 1
