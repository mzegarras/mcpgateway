#!/usr/bin/env bash
# Verifica el guardrail de contenido externo (ExtMcp/gRPC): el MISMO tool get_cliente
# devuelve el DNI en claro a quien tiene el rol 'pii.read' y enmascarado a quien no.
# Decisión por CONTEXTO (el JWT), enmascarado POR CAMPO (dni sí, nombre/id no).
#
# Uso: ./test-guardrail-pii.sh [usuario_claro] [usuario_mask]   (por defecto ana / luis)
set -u
U_CLEAR=${1:-ana}        # tiene pii.read  -> debe ver el DNI completo
U_MASK=${2:-luis}        # NO tiene pii.read -> debe ver el DNI enmascarado
GW=http://localhost:3000/mcp
DNI=45678912             # DNI "sucio" que inyecta mcp-cuentas en get_cliente
LAST4=${DNI: -4}
ID=c-100
HERE=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)"; exit 1; }
first_json() { sed -n 's/^data: //p; /^{/p' | head -n1; }

FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# get_dni <usuario> -> imprime el valor del campo 'dni' que recibe ese usuario
get_dni() {
  local user=$1 tok sid
  tok=$("$HERE/get-jwt.sh" "$user") || { echo "ERR_TOKEN"; return; }
  local H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $tok")
  curl -s -D /tmp/gpii_h -o /dev/null "$GW" "${H[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pii","version":"1"}}}'
  sid=$(grep -i '^mcp-session-id:' /tmp/gpii_h | awk '{print $2}' | tr -d '\r')
  curl -s -o /dev/null "$GW" "${H[@]}" -H "Mcp-Session-Id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s "$GW" "${H[@]}" -H "Mcp-Session-Id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"cuentas_get_cliente\",\"arguments\":{\"id\":\"$ID\"}}}" \
    | first_json | jq -r '.result.structuredContent.dni // "SIN_DNI"'
}

echo "== 1) '$U_MASK' (SIN pii.read) debe recibir el DNI ENMASCARADO"
T_MASK=$(get_dni "$U_MASK")
echo "  dni: $T_MASK"
if [[ "$T_MASK" == "$DNI" ]]; then
  fail "'$U_MASK' recibió el DNI en claro (no se enmascaró)"
elif [[ "$T_MASK" == *"*"* && "$T_MASK" == *"$LAST4" ]]; then
  pass "enmascarado, solo últimos 4 visibles ($LAST4)"
else
  fail "valor inesperado: '$T_MASK'"
fi

echo
echo "== 2) '$U_CLEAR' (CON pii.read) debe recibir el DNI EN CLARO"
T_CLEAR=$(get_dni "$U_CLEAR")
echo "  dni: $T_CLEAR"
if [[ "$T_CLEAR" == "$DNI" ]]; then
  pass "'$U_CLEAR' ve el DNI completo"
else
  fail "'$U_CLEAR' no recibió el DNI en claro (obtuvo '$T_CLEAR')"
fi

echo
echo "== 3) el enmascarado es POR CAMPO (nombre/id intactos para '$U_MASK')"
tok=$("$HERE/get-jwt.sh" "$U_MASK")
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $tok")
curl -s -D /tmp/gpii_h -o /dev/null "$GW" "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pii","version":"1"}}}'
SID=$(grep -i '^mcp-session-id:' /tmp/gpii_h | awk '{print $2}' | tr -d '\r')
curl -s -o /dev/null "$GW" "${H[@]}" -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
SC=$(curl -s "$GW" "${H[@]}" -H "Mcp-Session-Id: $SID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"cuentas_get_cliente\",\"arguments\":{\"id\":\"$ID\"}}}" \
  | first_json | jq -c '.result.structuredContent')
echo "  structuredContent: $SC"
NOMBRE=$(jq -r '.nombre' <<<"$SC"); CID=$(jq -r '.id' <<<"$SC")
if [[ "$NOMBRE" == "Maria Torres" && "$CID" == "$ID" ]]; then
  pass "nombre='Maria Torres' e id='$ID' sin alterar"
else
  fail "campos no sensibles alterados (nombre='$NOMBRE' id='$CID')"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "RESULTADO: OK — mismo tool, DNI en claro para '$U_CLEAR' y enmascarado para '$U_MASK'."
  exit 0
else
  echo "RESULTADO: $FAILS aserción(es) fallida(s)."
  exit 1
fi
