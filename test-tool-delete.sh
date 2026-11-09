#!/usr/bin/env bash
# Verifica el tool filtering de 'delete_account': el MCP de cuentas la expone, pero el
# gateway la FILTRA => (1) no aparece en tools/list y (2) la llamada directa da 403.
# Uso: ./test-tool-delete.sh [usuario] [password]     (por defecto ana/ana)
set -u
USER=${1:-ana}; PASS=${2:-$USER}
KC=http://localhost:8080
GW=http://localhost:3000/mcp
HDR=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
TOOL=cuentas_delete_account          # nombre expuesto por el gateway (target_tool)

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)"; exit 1; }

# Extrae el primer JSON de una respuesta JSON plano o SSE ("data: {...}")
first_json() { sed -n 's/^data: //p; /^{/p' | head -n1; }

FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

echo "== 1) Token de Keycloak para '$USER'"
TOKEN=$(curl -s -X POST "$KC/realms/manubank/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=mcp-gateway -d username="$USER" -d password="$PASS" \
  | jq -r '.access_token // empty')
[[ -n "$TOKEN" ]] || { echo "ERROR: no se obtuvo access_token"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")
echo "  OK"

echo
echo "== 2) initialize (abrir sesión MCP)"
curl -s -D /tmp/agw_del_hdr -o /dev/null "$GW" "${AUTH[@]}" "${HDR[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-del","version":"1"}}}'
SID=$(grep -i '^mcp-session-id:' /tmp/agw_del_hdr | awk '{print $2}' | tr -d '\r')
SIDH=(); [[ -n "$SID" ]] && SIDH=(-H "Mcp-Session-Id: $SID")
curl -s -o /dev/null "$GW" "${AUTH[@]}" "${HDR[@]}" "${SIDH[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
echo "  session: ${SID:-<sin Mcp-Session-Id>}"

echo
echo "== 3) tools/list NO debe contener 'delete_account'"
LIST=$(curl -s "$GW" "${AUTH[@]}" "${HDR[@]}" "${SIDH[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | first_json)
NAMES=$(jq -r '.result.tools[]?.name' <<<"$LIST")
echo "  tools visibles: $(echo $NAMES | tr '\n' ' ')"
if grep -q 'delete_account' <<<"$NAMES"; then
  fail "'delete_account' aparece en tools/list (debería estar filtrada)"
else
  pass "'delete_account' NO aparece en tools/list (filtrada)"
fi

echo
echo "== 4) tools/call $TOOL debe bloquearse (HTTP 403)"
CODE=$(curl -s -o /tmp/agw_del_body -w '%{http_code}' "$GW" "${AUTH[@]}" "${HDR[@]}" "${SIDH[@]}" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":{\"cuenta\":\"191-1\"}}}")
echo "  HTTP $CODE  cuerpo: $(cat /tmp/agw_del_body)"
if [[ "$CODE" == "403" ]]; then
  pass "la llamada directa fue rechazada con 403"
else
  fail "se esperaba 403 y se obtuvo $CODE (¿se ejecutó delete_account?)"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "RESULTADO: OK — 'delete_account' está correctamente filtrada."
  exit 0
else
  echo "RESULTADO: $FAILS aserción(es) fallida(s)."
  exit 1
fi
