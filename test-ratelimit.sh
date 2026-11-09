#!/usr/bin/env bash
# Prueba del RATE LIMIT remoto (RLS + Redis), que aplica SOLO a la tool 'transferir'.
# Dispara ráfagas de 3 tipos de request y muestra cuáles se limitan:
#   - initialize        (handshake)   -> NO debe limitarse
#   - cuentas_get_saldo (otra tool)   -> NO debe limitarse
#   - pagos_transferir  (tool objetivo) -> SÍ, tras superar el límite por minuto
#
# Uso: ./test-ratelimit.sh [usuario] [password] [n_requests]   (por defecto ana/ana 15)
# Nota: el contador es POR USUARIO y POR MINUTO. Correrlo dos veces seguidas en el
#       mismo minuto mostrará 'transferir' limitado desde el primer request.
set -u
USER=${1:-ana}; PASS=${2:-$USER}; N=${3:-15}
KC=http://localhost:8080
GW=http://localhost:3000/mcp
AUTHHDR=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)"; exit 1; }

echo "== Token de Keycloak para '$USER'"
TOKEN=$(curl -s -X POST "$KC/realms/manubank/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=mcp-gateway -d username="$USER" -d password="$PASS" \
  | jq -r '.access_token // empty')
[[ -z "$TOKEN" ]] && { echo "ERROR: no se obtuvo access_token (¿usuario/clave válidos?)"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" "${AUTHHDR[@]}")
echo "   OK"

INITB='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rl-test","version":"1"}}}'

# Sesión MCP para poder invocar tools/call
SID=$(curl -s -D - -o /dev/null "$GW" "${AUTH[@]}" -d "$INITB" \
  | grep -i '^mcp-session-id:' | awk '{print $2}' | tr -d '\r')
[[ -z "$SID" ]] && { echo "ERROR: el gateway no devolvió Mcp-Session-Id (ver: docker compose logs agentgateway)"; exit 1; }
SIDH=(-H "Mcp-Session-Id: $SID")
curl -s -o /dev/null "$GW" "${AUTH[@]}" "${SIDH[@]}" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

# burst <etiqueta> <body-json>  -> dispara N requests y cuenta cuántos fueron limitados
burst() {
  local label=$1 body=$2 limited=0 ok=0 i resp
  echo
  echo "== ${N}x ${label}"
  for i in $(seq 1 "$N"); do
    resp=$(curl -s "$GW" "${AUTH[@]}" "${SIDH[@]}" -d "$body")
    if grep -qi "rate limit" <<<"$resp"; then
      limited=$((limited+1)); printf "  %2d -> 🚫 RATE-LIMITED\n" "$i"
    else
      ok=$((ok+1));           printf "  %2d -> ✅ no-limitado\n" "$i"
    fi
  done
  printf "   >> %s: %d pasaron, %d limitados\n" "$label" "$ok" "$limited"
  eval "RES_${label}=$limited"
}

burst initialize       "$INITB"
burst get_saldo        '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cuentas_get_saldo","arguments":{"cuenta":"191-1"}}}'
burst transferir       '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"pagos_transferir","arguments":{"origen":"191-1","destino":"191-2","monto":100}}}'

echo
echo "== Veredicto"
if [[ "${RES_initialize:-0}" -eq 0 && "${RES_get_saldo:-0}" -eq 0 && "${RES_transferir:-0}" -gt 0 ]]; then
  echo "   ✅ Correcto: el rate limit aplica SOLO a 'transferir' (handshake y otras tools libres)."
else
  echo "   ⚠️  Inesperado: initialize=${RES_initialize:-0} get_saldo=${RES_get_saldo:-0} transferir=${RES_transferir:-0} limitados."
  echo "      (si 'transferir'=0, quizá N<=límite o la ventana ya reseteó; sube N o reintenta)"
fi
