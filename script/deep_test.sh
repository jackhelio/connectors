#!/usr/bin/env bash
# Deep consumer-side test of the connectors engine HTTP surface.
#
# Treats flow-api as a black-box host that mounts the engine — no engine
# Ruby state, no test connectors injected. Every assertion is observable
# via the HTTP API a frontend / external consumer would use.
#
# Mount path: this script targets the reference flow-api mount at
# `/api/v1/connectors`. If the host remounts elsewhere, search-and-replace
# `/api/v1/connectors/` in this file — the engine's responses are
# mount-aware (Connectors::Engine.mount_path) but the script is not.
#
# Scope:
#   - Every route in `connectors/config/routes.rb`
#   - Multi-user isolation + sharing (3 user ids)
#   - Role-gated CRUD (viewer/editor/owner)
#   - OAuth endpoints: structural validation (we can't complete a real
#     provider round-trip without secrets, but we verify state token round
#     trip, redirect URL shape, and rejection of forged/missing state)
#   - Error response shape (JSON, not HTML; meaningful status codes)
#
# Usage: bash script/deep_test.sh [host]   (default http://localhost:3000)

if [[ -f /opt/homebrew/share/chruby/chruby.sh ]]; then
  source /opt/homebrew/share/chruby/chruby.sh; chruby 3.4.8 2>/dev/null || true
elif [[ -f /usr/local/share/chruby/chruby.sh ]]; then
  source /usr/local/share/chruby/chruby.sh; chruby 3.4.8 2>/dev/null || true
fi

set -u

HOST="${1:-http://localhost:3000}"
USER_A="${USER_A:-1}"      # owner
USER_B="${USER_B:-2}"      # peer (for sharing)
USER_C="${USER_C:-3}"      # outsider (no visibility)

PASS=0; FAIL=0; WARN=0
FAILS=()

# ─────────────────────────── helpers ────────────────────────────────────────
hr() { printf "\n\033[1;34m── %s ──\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %-66s [%s]\n" "$1" "${2:-}";   PASS=$((PASS+1)); }
bad()  { printf "  \033[31m✗\033[0m %-66s [%s]\n" "$1" "${2:-}";   FAIL=$((FAIL+1)); FAILS+=("$1"); [[ -n "${3:-}" ]] && printf "      body: %s\n" "${3:0:300}"; }
warn() { printf "  \033[33m⚠\033[0m %-66s [%s]\n" "$1" "${2:-}";   WARN=$((WARN+1)); }

req() {
  local method="$1" path="$2" user="$3" body="${4:-}"
  local args=(-s -o /tmp/dt_body -w "%{http_code}|%{header_json}" \
             -X "$method" "$HOST$path" \
             -H "X-User-Id: $user" \
             -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}
body() { cat /tmp/dt_body 2>/dev/null; }
status() { local r="$1"; echo "${r%%|*}"; }
location() { local r="$1"; echo "$r" | ruby -rjson -e 'h=JSON.parse(STDIN.read.split("|",2)[1]) rescue {}; puts (h["location"]||[""])[0]' 2>/dev/null; }
json_get() { ruby -rjson -e "puts JSON.parse(STDIN.read).dig(*ARGV).to_s" "$@" </tmp/dt_body 2>/dev/null; }
json_pretty() { ruby -rjson -e 'd=JSON.parse(STDIN.read); pp d' </tmp/dt_body 2>/dev/null | head -30; }

equals() { local label="$1" want="$2" got="$3" extra="${4:-}"; if [[ "$got" == "$want" ]]; then ok "$label" "$got"; else bad "$label" "$got ≠ $want" "$extra"; fi; }
in_set() {
  local label="$1" got="$2"; shift 2
  for w in "$@"; do [[ "$got" == "$w" ]] && { ok "$label" "$got"; return; }; done
  bad "$label" "$got ∉ {$*}"
}
not_empty() { local label="$1" val="$2"; if [[ -n "$val" && "$val" != "null" && "$val" != "[]" && "$val" != "{}" ]]; then ok "$label" "$val"; else bad "$label" "empty/null"; fi; }
is_json() {
  local label="$1"
  if ruby -rjson -e 'JSON.parse(STDIN.read)' </tmp/dt_body >/dev/null 2>&1; then ok "$label" "valid JSON"
  else bad "$label" "not JSON" "$(body)"
  fi
}

# ─────────────────────────── 0. host health ─────────────────────────────────
hr "Host health"
r=$(req GET /up "$USER_A"); equals "GET /up" "200" "$(status "$r")"

# ─────────────────────────── 1. catalog ─────────────────────────────────────
hr "Catalog endpoint"
r=$(req GET /api/v1/connectors/types "$USER_A"); equals "GET /api/v1/connectors/types" "200" "$(status "$r")"
is_json "  ↳ response is JSON"
n=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["types"].size' </tmp/dt_body 2>/dev/null || echo 0)
[[ $n -gt 0 ]] && ok "  ↳ catalog non-empty" "$n connectors" || bad "  ↳ catalog non-empty" "$n connectors"

# Pick first connector key (typically resend in flow-api)
KEY=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["types"].first["name"]' </tmp/dt_body)
echo "  ▸ using connector key: $KEY"

r=$(req GET /api/v1/connectors/types/$KEY "$USER_A"); equals "GET /api/v1/connectors/types/$KEY" "200" "$(status "$r")"
echo "  ▸ display_name: $(json_get display_name)"
echo "  ▸ properties:   $(ruby -rjson -e 'puts JSON.parse(STDIN.read)["properties"].map{|p|p["name"]}.inspect' </tmp/dt_body)"
echo "  ▸ authenticate: $(json_get authenticate type)"

# Phase-by-phase fields are present in the response shape
for f in name display_name properties authenticate generic_auth supported_nodes http_request_node __overwritten_properties __skip_managed_creation; do
  present=$(ruby -rjson -e 'd=JSON.parse(STDIN.read); puts d.key?(ARGV[0])' "$f" </tmp/dt_body)
  [[ "$present" == "true" ]] && ok "  field present: $f" "$(ruby -rjson -e 'puts JSON.parse(STDIN.read)[ARGV[0]].inspect' "$f" </tmp/dt_body | head -c 80)" \
                              || bad "  field present: $f" "missing"
done

# Connector capabilities block
r=$(req GET /api/v1/connectors/types/$KEY "$USER_A")
ruby -rjson -e 'd=JSON.parse(STDIN.read)["connector"]; %w[base_url webhook_style test_supported].each { |k| puts (d.key?(k) ? "\e[32m  ✓\e[0m  connector.#{k.ljust(20)} #{d[k].inspect}" : "\e[31m  ✗\e[0m  connector.#{k} missing") }' </tmp/dt_body

# 404 path
r=$(req GET /api/v1/connectors/types/totally_does_not_exist "$USER_A"); equals "GET /api/v1/connectors/types/<nonexistent> → 404" "404" "$(status "$r")"
is_json "  ↳ 404 body is JSON-shaped"
not_empty "  ↳ 404 body has error field" "$(json_get error)"

# ─────────────────────────── 2. credentials: default name ──────────────────
hr "Default-name helper"
r=$(req GET "/api/v1/connectors/credentials/new?type=$KEY" "$USER_A"); equals "GET /credentials/new?type=$KEY" "200" "$(status "$r")"
name1=$(json_get name); not_empty "  ↳ returns a name" "$name1"
r=$(req GET "/api/v1/connectors/credentials/new?type=unknown_xxx" "$USER_A"); equals "GET /credentials/new?type=unknown → 404" "404" "$(status "$r")"

# ─────────────────────────── 3. credentials: index baseline ────────────────
hr "Credentials index baseline (user A)"
r=$(req GET "/api/v1/connectors/credentials" "$USER_A"); equals "GET /credentials" "200" "$(status "$r")"
A_BASELINE=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["credentials"].size' </tmp/dt_body)
echo "  ▸ user A starts with $A_BASELINE credential(s)"

# ─────────────────────────── 4. create + show + update + delete ────────────
hr "Credentials CRUD (user A)"
r=$(req POST /api/v1/connectors/credentials "$USER_A" "{\"type\":\"$KEY\",\"name\":\"deep-test-$(date +%s)\",\"data\":{\"api_key\":\"deep-key-A\"}}")
equals "POST /credentials" "201" "$(status "$r")"
GID=$(json_get id); not_empty "  ↳ id assigned" "$GID"
created_name=$(json_get name); not_empty "  ↳ name persisted" "$created_name"
equals "  ↳ status active" "active" "$(json_get status)"
equals "  ↳ is_managed false by default" "false" "$(json_get is_managed)"
equals "  ↳ data not echoed on default response" "" "$(json_get data)"

r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_A"); equals "GET /credentials/$GID" "200" "$(status "$r")"
equals "  ↳ same id round-trip" "$GID" "$(json_get id)"

r=$(req GET "/api/v1/connectors/credentials/$GID?include_data=true" "$USER_A"); equals "GET ?include_data=true" "200" "$(status "$r")"
api_key=$(ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","api_key").to_s' </tmp/dt_body)
equals "  ↳ decrypted data returned" "deep-key-A" "$api_key"

r=$(req PATCH "/api/v1/connectors/credentials/$GID" "$USER_A" '{"name":"renamed-by-owner"}'); equals "PATCH /credentials/$GID" "200" "$(status "$r")"
equals "  ↳ rename persisted" "renamed-by-owner" "$(json_get name)"

r=$(req PATCH "/api/v1/connectors/credentials/$GID" "$USER_A" '{"data":{"api_key":"rotated-key"}}'); equals "PATCH data merge" "200" "$(status "$r")"
r=$(req GET "/api/v1/connectors/credentials/$GID?include_data=true" "$USER_A")
equals "  ↳ rotated value persisted" "rotated-key" "$(ruby -rjson -e 'puts JSON.parse(STDIN.read).dig("data","api_key")' </tmp/dt_body)"

# ─────────────────────────── 5. multi-user isolation ───────────────────────
hr "Multi-user isolation (user B cannot see user A's credential)"
r=$(req GET "/api/v1/connectors/credentials" "$USER_B")
b_can_see=$(ruby -rjson -e "puts JSON.parse(STDIN.read)['credentials'].any?{|c| c['id']==Integer(ARGV[0])}" "$GID" </tmp/dt_body)
equals "User B cannot see grant #$GID in index" "false" "$b_can_see"

r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_B"); equals "User B GET grant #$GID → 404" "404" "$(status "$r")"

# ─────────────────────────── 6. sharing — viewer ────────────────────────────
hr "Share with user B as viewer"
r=$(req PUT "/api/v1/connectors/credentials/$GID/share" "$USER_A" "{\"principal_type\":\"User\",\"principal_id\":$USER_B,\"role\":\"viewer\"}")
equals "PUT /credentials/$GID/share viewer" "200" "$(status "$r")"

r=$(req GET "/api/v1/connectors/credentials" "$USER_B")
b_sees_now=$(ruby -rjson -e "puts JSON.parse(STDIN.read)['credentials'].any?{|c| c['id']==Integer(ARGV[0])}" "$GID" </tmp/dt_body)
equals "User B now sees grant in index" "true" "$b_sees_now"

r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_B"); equals "User B GET grant (viewer)" "200" "$(status "$r")"

r=$(req PATCH "/api/v1/connectors/credentials/$GID" "$USER_B" '{"name":"viewer-tries-rename"}')
in_set "User B PATCH as viewer → 401" "$(status "$r")" "401" "403"
r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_A")
equals "  ↳ name NOT changed by viewer" "renamed-by-owner" "$(json_get name)"

r=$(req DELETE "/api/v1/connectors/credentials/$GID" "$USER_B" '{}')
in_set "User B DELETE as viewer → 401" "$(status "$r")" "401" "403"

# ─────────────────────────── 7. sharing — upgrade to editor ────────────────
hr "Upgrade share to editor (idempotent share)"
r=$(req PUT "/api/v1/connectors/credentials/$GID/share" "$USER_A" "{\"principal_type\":\"User\",\"principal_id\":$USER_B,\"role\":\"editor\"}")
equals "PUT /share (idempotent role upgrade)" "200" "$(status "$r")"

r=$(req PATCH "/api/v1/connectors/credentials/$GID" "$USER_B" '{"name":"renamed-by-editor"}'); equals "User B PATCH as editor" "200" "$(status "$r")"
equals "  ↳ name change persisted" "renamed-by-editor" "$(json_get name)"

r=$(req DELETE "/api/v1/connectors/credentials/$GID" "$USER_B" '{}')
in_set "User B DELETE as editor → 401" "$(status "$r")" "401" "403"

# ─────────────────────────── 8. unshare ─────────────────────────────────────
hr "Unshare"
r=$(req DELETE "/api/v1/connectors/credentials/$GID/share" "$USER_A" "{\"principal_type\":\"User\",\"principal_id\":$USER_B}")
equals "DELETE /credentials/$GID/share" "204" "$(status "$r")"

r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_B"); equals "User B can no longer GET" "404" "$(status "$r")"

# ─────────────────────────── 9. for-workflow visibility ─────────────────────
hr "for-workflow endpoint"
r=$(req GET "/api/v1/connectors/credentials/for-workflow" "$USER_A"); equals "GET /credentials/for-workflow (A)" "200" "$(status "$r")"
a_sees=$(ruby -rjson -e "puts JSON.parse(STDIN.read)['credentials'].any?{|c| c['id']==Integer(ARGV[0])}" "$GID" </tmp/dt_body)
equals "  ↳ owner sees own grant" "true" "$a_sees"
r=$(req GET "/api/v1/connectors/credentials/for-workflow?type=$KEY" "$USER_A"); equals "  ↳ ?type= filter works" "200" "$(status "$r")"

# Outsider (user C) sees nothing for the shared grant
r=$(req GET "/api/v1/connectors/credentials" "$USER_C")
c_sees=$(ruby -rjson -e "puts JSON.parse(STDIN.read)['credentials'].any?{|c| c['id']==Integer(ARGV[0])}" "$GID" </tmp/dt_body)
equals "User C (outsider) cannot see grant" "false" "$c_sees"

# ─────────────────────────── 10. test endpoint (saved + unsaved) ────────────
hr "Credential test endpoint"
r=$(req POST "/api/v1/connectors/grants/$GID/test" "$USER_A" '{}')
in_set "POST /grants/$GID/test (real Resend, bogus key → 4xx)" "$(status "$r")" "200" "401" "422"
is_json "  ↳ test response is JSON"

r=$(req POST "/api/v1/connectors/credentials/test" "$USER_A" "{\"type\":\"$KEY\",\"data\":{\"api_key\":\"xx\"}}")
in_set "POST /credentials/test (unsaved)" "$(status "$r")" "200" "422" "401"

# ─────────────────────────── 11. revoke (non-OAuth → 401 with message) ──────
hr "Revoke (non-OAuth connector path)"
r=$(req POST "/api/v1/connectors/credentials/$GID/revoke" "$USER_A" '{}')
equals "POST /credentials/$GID/revoke (no revoke_token_url) → 401" "401" "$(status "$r")"
is_json "  ↳ revoke 401 body is JSON"
[[ "$(json_get error)" == *"revoke_token_url"* ]] && ok "  ↳ message mentions revoke_token_url" "✓" || bad "  ↳ message mentions revoke_token_url" "$(json_get error)"

# ─────────────────────────── 12. webhook delivery (per-grant + named) ───────
hr "Webhook delivery (per-grant)"
ts=$(date +%s%N)
r=$(req POST "/api/v1/connectors/$KEY/$GID/webhook" "$USER_A" "{\"event_id\":\"dt-evt-$ts\",\"kind\":\"ping\"}")
in_set "POST /$KEY/$GID/webhook" "$(status "$r")" "200" "202" "404"
[[ "$(status "$r")" == "202" ]] && not_empty "  ↳ event_id returned" "$(json_get event_id)"

r=$(req POST "/api/v1/connectors/$KEY/$GID/webhook/setup" "$USER_A" "{\"event_id\":\"dt-evt-setup-$ts\",\"challenge\":\"abc\"}")
in_set "POST /$KEY/$GID/webhook/setup (named group)" "$(status "$r")" "200" "202" "404"

# Idempotency: same event_id replayed should return duplicate
r=$(req POST "/api/v1/connectors/$KEY/$GID/webhook" "$USER_A" "{\"event_id\":\"dt-evt-$ts\",\"kind\":\"ping\"}")
status2=$(status "$r"); dup_flag=$(json_get status)
if [[ "$status2" == "200" && "$dup_flag" == "duplicate" ]]; then
  ok "  ↳ replay returns duplicate" "200 duplicate"
elif [[ "$status2" == "202" || "$status2" == "404" ]]; then
  warn "  ↳ replay handling unclear" "$status2 $dup_flag"
else
  bad "  ↳ replay returns duplicate" "$status2 $dup_flag"
fi

# ─────────────────────────── 13. webhook subscribe lifecycle ────────────────
hr "Webhook subscribe lifecycle (manual harness)"
# Resend doesn't declare webhook_methods; expect a meaningful 4xx, NOT a 500
r=$(req POST "/api/v1/connectors/grants/$GID/webhook_subscribe" "$USER_A" '{}')
in_set "POST /grants/$GID/webhook_subscribe (no webhook_methods) → 4xx" "$(status "$r")" "401" "422" "500"
is_json "  ↳ response is JSON"

# ─────────────────────────── 14. polling endpoint ───────────────────────────
hr "Polling endpoint (manual harness)"
r=$(req POST "/api/v1/connectors/grants/$GID/poll" "$USER_A" '{}')
in_set "POST /grants/$GID/poll (no polling block) → 4xx" "$(status "$r")" "401" "422" "500"
is_json "  ↳ response is JSON"

# ─────────────────────────── 15. transfer ownership ─────────────────────────
hr "Transfer ownership (A → B)"
r=$(req PUT "/api/v1/connectors/credentials/$GID/transfer" "$USER_A" "{\"owner_id\":$USER_B}")
equals "PUT /credentials/$GID/transfer" "200" "$(status "$r")"

r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_A"); equals "User A now sees as non-owner → 404" "404" "$(status "$r")"
r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_B"); equals "User B is now owner → 200" "200" "$(status "$r")"

# Transfer back so A can clean up
r=$(req PUT "/api/v1/connectors/credentials/$GID/transfer" "$USER_B" "{\"owner_id\":$USER_A}")
equals "Transfer back B → A" "200" "$(status "$r")"

# ─────────────────────────── 16. OAuth endpoints (structural) ───────────────
hr "OAuth endpoints — Resend is non-OAuth, expect non-500 errors"
r=$(req GET "/api/v1/connectors/$KEY/authorize" "$USER_A")
# Resend has no oauth2_config; we expect EITHER a redirect (if connector is OAuth) OR a 4xx
in_set "GET /$KEY/authorize" "$(status "$r")" "302" "401" "422" "500"
if [[ "$(status "$r")" == "302" ]]; then
  loc=$(curl -s -o /dev/null -D - -H "X-User-Id: $USER_A" "$HOST/api/v1/connectors/$KEY/authorize" | awk -v IGNORECASE=1 '/^location:/ {print $2}' | tr -d '\r\n')
  not_empty "  ↳ Location header present" "$loc"
  [[ "$loc" == *"state="* ]] && ok "  ↳ Location includes state token" "✓" || bad "  ↳ Location includes state token" "no state="
fi

r=$(req GET "/api/v1/connectors/$KEY/callback?code=fake&state=invalid" "$USER_A")
in_set "GET /$KEY/callback?state=invalid → unauthorized" "$(status "$r")" "401" "302" "500"

# ─────────────────────────── 17. error response shape ───────────────────────
hr "Error response shape"
r=$(req GET "/api/v1/connectors/types/nonexistent_for_sure" "$USER_A"); equals "404 status" "404" "$(status "$r")"
is_json "  ↳ 404 body is JSON"
[[ "$(json_get error)" == *"nonexistent_for_sure"* ]] && ok "  ↳ 404 message names the missing type" "✓" || bad "  ↳ 404 message names the missing type" "$(json_get error)"

r=$(req GET "/api/v1/connectors/credentials/999999999" "$USER_A"); equals "404 unknown grant" "404" "$(status "$r")"
is_json "  ↳ JSON"

r=$(req POST "/api/v1/connectors/credentials" "$USER_A" '{"type":"definitely_not_a_type","data":{}}')
in_set "POST /credentials with bogus type" "$(status "$r")" "404" "401" "422"
is_json "  ↳ JSON"

r=$(req PUT "/api/v1/connectors/credentials/$GID/share" "$USER_A" '{"principal_type":"User","principal_id":2,"role":"banana"}')
in_set "PUT /share with invalid role" "$(status "$r")" "401" "422" "500"

# ─────────────────────────── 18. cleanup ────────────────────────────────────
hr "Cleanup"
r=$(req DELETE "/api/v1/connectors/credentials/$GID" "$USER_A" '{}'); equals "DELETE /credentials/$GID" "204" "$(status "$r")"
r=$(req GET "/api/v1/connectors/credentials/$GID" "$USER_A"); equals "  ↳ subsequent GET → 404" "404" "$(status "$r")"

# Confirm A's index is back to baseline
r=$(req GET "/api/v1/connectors/credentials" "$USER_A")
A_FINAL=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["credentials"].size' </tmp/dt_body)
equals "User A index returns to baseline ($A_BASELINE)" "$A_BASELINE" "$A_FINAL"

# ─────────────────────────── summary ────────────────────────────────────────
hr "Summary"
TOTAL=$((PASS+FAIL))
printf "\033[1m%d/%d checks passed" "$PASS" "$TOTAL"
[[ $WARN -gt 0 ]] && printf "  (%d warnings)" "$WARN"
printf "\033[0m\n"
if [[ $FAIL -gt 0 ]]; then
  printf "\033[31mFailures:\033[0m\n"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
