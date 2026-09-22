#!/usr/bin/env bash
# End-to-end smoke test for the connectors engine. Hits every HTTP endpoint
# against a running flow-api and prints pass/fail with the actual response.
# Usage: bash script/e2e_smoke.sh [host]   (default http://localhost:3500)

# NOTE: chruby's loader references unset vars before its own defaults, so
# DON'T `set -u` until after sourcing it.
if [[ -f /opt/homebrew/share/chruby/chruby.sh ]]; then
  source /opt/homebrew/share/chruby/chruby.sh
  chruby 3.4.8 2>/dev/null || true
elif [[ -f /usr/local/share/chruby/chruby.sh ]]; then
  source /usr/local/share/chruby/chruby.sh
  chruby 3.4.8 2>/dev/null || true
fi

set -u

HOST="${1:-http://localhost:3500}"
USER_ID="${X_USER_ID:-1}"
PASS=0
FAIL=0
FAILS=()

# --- helpers -----------------------------------------------------------------
hr() { printf "\n\033[1;34m── %s ──\033[0m\n" "$1"; }
check() {
  local label="$1" expected="$2" got="$3" body="${4:-}"
  if [[ "$got" == "$expected" ]]; then
    printf "  \033[32m✓\033[0m %-60s [%s]\n" "$label" "$got"
    PASS=$((PASS+1))
  else
    printf "  \033[31m✗\033[0m %-60s [%s ≠ %s]\n" "$label" "$got" "$expected"
    [[ -n "$body" ]] && printf "      body: %s\n" "${body:0:240}"
    FAIL=$((FAIL+1))
    FAILS+=("$label")
  fi
}
req() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -o /tmp/connectors_smoke_body.json -w "%{http_code}" \
             -X "$method" "$HOST$path" \
             -H "X-User-Id: $USER_ID" \
             -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}
body() { cat /tmp/connectors_smoke_body.json 2>/dev/null; }
json_get() { ruby -rjson -e "puts JSON.parse(STDIN.read).dig(*ARGV) rescue ''" "$@" </tmp/connectors_smoke_body.json; }

# --- 0. host health ----------------------------------------------------------
hr "Host health"
code=$(curl -sf -o /dev/null -w '%{http_code}' "$HOST/up")
check "GET /up" "200" "$code"

# --- 1. catalog --------------------------------------------------------------
hr "Catalog"
code=$(req GET /connectors/types); check "GET /connectors/types" "200" "$code" "$(body)"

# At least one connector must be present (Resend ships in flow-api)
n_types=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["types"].size rescue 0' </tmp/connectors_smoke_body.json)
check "  ↳ catalog non-empty" "true" "$([[ $n_types -gt 0 ]] && echo true || echo false)" "n_types=$n_types"

# Pick the first connector key to drive subsequent tests
KEY=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["types"].first["name"] rescue ""' </tmp/connectors_smoke_body.json)
echo "  Using connector key: $KEY"

code=$(req GET "/connectors/types/$KEY"); check "GET /connectors/types/$KEY" "200" "$code" "$(body)"
code=$(req GET "/connectors/types/nonexistent_xyz"); check "GET /connectors/types/nonexistent (404)" "404" "$code"

# --- 2. credentials index (empty initially for this user / type) ------------
hr "Credentials — index baseline"
code=$(req GET "/connectors/credentials?type=$KEY"); check "GET /credentials?type=$KEY" "200" "$code"
code=$(req GET "/connectors/credentials/for-workflow"); check "GET /credentials/for-workflow" "200" "$code"

# --- 3. unique default name --------------------------------------------------
hr "Default-name helper (Phase 11)"
code=$(req GET "/connectors/credentials/new?type=$KEY")
check "GET /credentials/new?type=$KEY" "200" "$code" "$(body)"
suggested=$(ruby -rjson -e 'puts JSON.parse(STDIN.read)["name"]' </tmp/connectors_smoke_body.json)
check "  ↳ returned a non-empty name" "true" "$([[ -n "$suggested" ]] && echo true || echo false)" "name=$suggested"

# --- 4. create + read + update + delete --------------------------------------
hr "Credentials CRUD"
code=$(req POST /connectors/credentials \
  "{\"type\":\"$KEY\",\"name\":\"smoke-$(date +%s)\",\"data\":{\"api_key\":\"smoke-key-1\"}}")
check "POST /credentials" "201" "$code" "$(body)"
ID=$(json_get id)
echo "  Created credential id: $ID"

code=$(req GET "/connectors/credentials/$ID"); check "GET /credentials/$ID" "200" "$code"
got_managed=$(json_get is_managed)
got_overwritten=$(ruby -rjson -e 'p JSON.parse(STDIN.read)["__overwritten_properties"]' </tmp/connectors_smoke_body.json)
check "  ↳ is_managed defaults false" "false" "$got_managed"
echo "  __overwritten_properties: $got_overwritten"

code=$(req PATCH "/connectors/credentials/$ID" '{"name":"smoke-renamed"}')
check "PATCH /credentials/$ID" "200" "$code" "$(body)"

# --- 5. test (unsaved) -------------------------------------------------------
hr "Credential test (unsaved)"
code=$(req POST /connectors/credentials/test \
  "{\"type\":\"$KEY\",\"data\":{\"api_key\":\"will-fail-against-real-api\"}}")
# Either OK (mock) or 422 (real provider rejected) is fine — endpoint just must respond
check "POST /credentials/test responds 2xx or 422" "true" \
  "$([[ "$code" == "200" || "$code" == "422" ]] && echo true || echo false)" \
  "code=$code body=$(body)"

# --- 6. share / unshare / transfer -------------------------------------------
hr "Sharing (Phase 9)"
code=$(req PUT "/connectors/credentials/$ID/share" \
  '{"principal_type":"User","principal_id":2,"role":"viewer"}')
check "PUT /credentials/$ID/share (viewer to User#2)" "200" "$code" "$(body)"

code=$(req PUT "/connectors/credentials/$ID/share" \
  '{"principal_type":"User","principal_id":2,"role":"editor"}')
check "  ↳ second call upgrades role (idempotent)" "200" "$code"

code=$(req DELETE "/connectors/credentials/$ID/share" \
  '{"principal_type":"User","principal_id":2}')
check "DELETE /credentials/$ID/share" "204" "$code"

# --- 7. catalog flags -------------------------------------------------------
hr "Phase 5/11 flags on types endpoint"
code=$(req GET "/connectors/types/$KEY")
check "GET /connectors/types/$KEY" "200" "$code"
echo "  generic_auth:        $(json_get generic_auth)"
echo "  supported_nodes:     $(ruby -rjson -e 'p JSON.parse(STDIN.read)["supported_nodes"]' </tmp/connectors_smoke_body.json)"
echo "  http_request_node:   $(ruby -rjson -e 'p JSON.parse(STDIN.read)["http_request_node"]' </tmp/connectors_smoke_body.json)"
echo "  authenticate:        $(ruby -rjson -e 'p JSON.parse(STDIN.read)["authenticate"]' </tmp/connectors_smoke_body.json)"

# --- 8. webhook delivery (per-grant) -----------------------------------------
hr "Inbound webhook delivery (per-grant)"
# Use a unique event id per run so the idempotency layer doesn't dedupe a
# repeat smoke against the same DB.
code=$(req POST "/connectors/$KEY/$ID/webhook" "{\"event_id\":\"smoke-evt-$(date +%s%N)\",\"kind\":\"ping\"}")
# 202 (queued), 200 (duplicate or challenge), 401 (signature required), or
# 404 (no grant resolver) all acceptable depending on conn config.
check "POST /$KEY/$ID/webhook responds" "true" \
  "$([[ "$code" == "202" || "$code" == "200" || "$code" == "401" || "$code" == "404" ]] && echo true || echo false)" \
  "code=$code body=$(body)"

# --- 9. revoke ---------------------------------------------------------------
hr "Revoke (Phase 4)"
# Will likely fail because the test connector has no revoke_token_url
# configured — what we're checking is that the endpoint RESPONDS, not that
# revocation succeeds against a non-OAuth connector.
code=$(req POST "/connectors/credentials/$ID/revoke" '{}')
check "POST /credentials/$ID/revoke responds 2xx or 401" "true" \
  "$([[ "$code" == "200" || "$code" == "401" ]] && echo true || echo false)" \
  "code=$code body=$(body)"

# --- 10. cleanup -------------------------------------------------------------
hr "Cleanup"
code=$(req DELETE "/connectors/credentials/$ID")
check "DELETE /credentials/$ID" "204" "$code"

# --- summary ----------------------------------------------------------------
hr "Summary"
TOTAL=$((PASS + FAIL))
printf "\033[1m%d/%d checks passed\033[0m\n" "$PASS" "$TOTAL"
if [[ $FAIL -gt 0 ]]; then
  printf "\033[31mFailures:\033[0m\n"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
  exit 1
fi
