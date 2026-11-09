#!/usr/bin/env bash
# Prueba extremo a extremo: Keycloak -> agentgateway -> MCPs.
# Uso: ./test.sh [usuario] [password]     (por defecto ana/ana)
# Imprime cada paso con su código HTTP y el cuerpo, y no se detiene en silencio.
set -u
USER=${1:-ana}; PASS=${2:-$USER}
KC=http://localhost:8080
GW=http://localhost:3000/mcp
HDR=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)"; exit 1; }

# Extrae el primer JSON de una respuesta que puede venir como JSON plano o como SSE ("data: {...}")
first_json() { sed -n 's/^data: //p; /^{/p' | head -n1; }

echo "== 1) Token de Keycloak para '$USER'"
TOK_RESP=$(curl -s -w '\n%{http_code}' -X POST "$KC/realms/manubank/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=mcp-gateway -d username="$USER" -d password="$PASS")
TOK_CODE=$(tail -n1 <<<"$TOK_RESP"); TOK_BODY=$(sed '$d' <<<"$TOK_RESP")
echo "HTTP $TOK_CODE"
TOKEN=$(jq -r '.access_token // empty' <<<"$TOK_BODY")
if [[ -z "$TOKEN" ]]; then echo "$TOK_BODY"; echo "ERROR: no se obtuvo access_token"; exit 1; fi
echo "claims relevantes:"
cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+' | awk '{l=length($0)%4; if(l) $0=$0 substr("===",1,4-l); print}' \
  | base64 -d 2>/dev/null | jq '{iss, aud, preferred_username, roles: .realm_access.roles, groups}'

echo
echo "== 2) initialize contra el gateway"
INIT=$(curl -s -D /tmp/agw_hdr -w '\n%{http_code}' "$GW" -H "Authorization: Bearer $TOKEN" "${HDR[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')
INIT_CODE=$(tail -n1 <<<"$INIT"); INIT_BODY=$(sed '$d' <<<"$INIT")
echo "HTTP $INIT_CODE"
if [[ "$INIT_CODE" != "200" ]]; then echo "$INIT_BODY"; echo "ERROR: el gateway rechazó initialize (ver: docker compose logs agentgateway)"; exit 1; fi
SID=$(grep -i '^mcp-session-id:' /tmp/agw_hdr | awk '{print $2}' | tr -d '\r')
echo "session: ${SID:-<sin Mcp-Session-Id>}"
SIDH=(); [[ -n "$SID" ]] && SIDH=(-H "Mcp-Session-Id: $SID")

# notificación initialized (algunos servers la exigen antes de tools/list)
curl -s -o /dev/null "$GW" -H "Authorization: Bearer $TOKEN" "${HDR[@]}" "${SIDH[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

echo
echo "== 3) tools/list (lo que ve '$USER' tras el filtrado del gateway)"
LIST=$(curl -s -w '\n%{http_code}' "$GW" -H "Authorization: Bearer $TOKEN" "${HDR[@]}" "${SIDH[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
LIST_CODE=$(tail -n1 <<<"$LIST"); LIST_BODY=$(sed '$d' <<<"$LIST" | first_json)
echo "HTTP $LIST_CODE"
if [[ -z "$LIST_BODY" ]]; then sed '$d' <<<"$LIST"; echo "ERROR: respuesta vacía o no parseable"; exit 1; fi
jq -r '.result.tools[]?.name // .error' <<<"$LIST_BODY"

call() { # $1=nombre tool, $2=argumentos JSON, $3=id
  local R; R=$(curl -s -w '\n%{http_code}' "$GW" -H "Authorization: Bearer $TOKEN" "${HDR[@]}" "${SIDH[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":$3,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}")
  echo "HTTP $(tail -n1 <<<"$R")"
  sed '$d' <<<"$R" | first_json | jq -c '.result // .error // .'
}

echo
echo "== 4) cuentas_get_saldo (cualquier usuario autenticado)"
call cuentas_get_saldo '{"cuenta":"191-1"}' 3

echo
echo "== 5) cuentas_get_movimientos (cualquier usuario autenticado)"
call cuentas_get_movimientos '{"cuenta":"191-1","dias":7}' 4

echo
echo "== 6) pagos_get_estado (requiere rol pagos.read)"
call pagos_get_estado '{"id_pago":"P-123"}' 5

echo
echo "== 7) pagos_transferir monto=100 (permitido solo con rol pagos.write)"
call pagos_transferir '{"origen":"191-1","destino":"191-2","monto":100}' 6

echo
echo "== 8) pagos_transferir monto=9000 (debe rechazarse por la regla monto <= 5000)"
call pagos_transferir '{"origen":"191-1","destino":"191-2","monto":9000}' 7
