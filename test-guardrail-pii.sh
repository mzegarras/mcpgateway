#!/usr/bin/env bash
# Verifica el guardrail de contenido externo (ExtMcp/gRPC): el MISMO tool get_saldo
# devuelve el PAN en claro a quien tiene el rol 'pii.read' y enmascarado a quien no.
# Decisión por CONTEXTO (el JWT), enmascarado POR CAMPO (tarjeta sí, saldo/cuenta no).
#
# Uso: ./test-guardrail-pii.sh [usuario_claro] [usuario_mask]   (por defecto ana / luis)
set -u
U_CLEAR=${1:-ana}        # tiene pii.read  -> debe ver el PAN completo
U_MASK=${2:-luis}        # NO tiene pii.read -> debe ver el PAN enmascarado
GW=http://localhost:3000/mcp
PAN=4539148803436467     # PAN "sucio" que inyecta mcp-cuentas en get_saldo
LAST4=${PAN: -4}
HERE=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)"; exit 1; }
first_json() { sed -n 's/^data: //p; /^{/p' | head -n1; }

FAILS=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS+1)); }

# get_tarjeta <usuario> -> imprime el valor del campo 'tarjeta' que recibe ese usuario
get_tarjeta() {
  local user=$1 tok sid
  tok=$("$HERE/get-jwt.sh" "$user") || { echo "ERR_TOKEN"; return; }
  local H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $tok")
  curl -s -D /tmp/gpii_h -o /dev/null "$GW" "${H[@]}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pii","version":"1"}}}'
  sid=$(grep -i '^mcp-session-id:' /tmp/gpii_h | awk '{print $2}' | tr -d '\r')
  curl -s -o /dev/null "$GW" "${H[@]}" -H "Mcp-Session-Id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  curl -s "$GW" "${H[@]}" -H "Mcp-Session-Id: $sid" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cuentas_get_saldo","arguments":{"cuenta":"191-1"}}}' \
    | first_json | jq -r '.result.structuredContent.tarjeta // "SIN_TARJETA"'
}

echo "== 1) '$U_MASK' (SIN pii.read) debe recibir la tarjeta ENMASCARADA"
T_MASK=$(get_tarjeta "$U_MASK")
echo "  tarjeta: $T_MASK"
if [[ "$T_MASK" == "$PAN" ]]; then
  fail "'$U_MASK' recibió el PAN en claro (no se enmascaró)"
elif [[ "$T_MASK" == *"*"* && "$T_MASK" == *"$LAST4" ]]; then
  pass "enmascarada, solo últimos 4 visibles ($LAST4)"
else
  fail "valor inesperado: '$T_MASK'"
fi

echo
echo "== 2) '$U_CLEAR' (CON pii.read) debe recibir la tarjeta EN CLARO"
T_CLEAR=$(get_tarjeta "$U_CLEAR")
echo "  tarjeta: $T_CLEAR"
if [[ "$T_CLEAR" == "$PAN" ]]; then
  pass "'$U_CLEAR' ve el PAN completo"
else
  fail "'$U_CLEAR' no recibió el PAN en claro (obtuvo '$T_CLEAR')"
fi

echo
echo "== 3) el enmascarado es POR CAMPO (saldo/cuenta intactos para '$U_MASK')"
tok=$("$HERE/get-jwt.sh" "$U_MASK")
H=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Authorization: Bearer $tok")
curl -s -D /tmp/gpii_h -o /dev/null "$GW" "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pii","version":"1"}}}'
SID=$(grep -i '^mcp-session-id:' /tmp/gpii_h | awk '{print $2}' | tr -d '\r')
curl -s -o /dev/null "$GW" "${H[@]}" -H "Mcp-Session-Id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
SC=$(curl -s "$GW" "${H[@]}" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"cuentas_get_saldo","arguments":{"cuenta":"191-1"}}}' \
  | first_json | jq -c '.result.structuredContent')
echo "  structuredContent: $SC"
SALDO=$(jq -r '.saldo' <<<"$SC"); CUENTA=$(jq -r '.cuenta' <<<"$SC")
if [[ "$SALDO" == "1250.75" && "$CUENTA" == "191-1" ]]; then
  pass "saldo=1250.75 y cuenta=191-1 sin alterar"
else
  fail "campos no sensibles alterados (saldo='$SALDO' cuenta='$CUENTA')"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "RESULTADO: OK — mismo tool, PAN en claro para '$U_CLEAR' y enmascarado para '$U_MASK'."
  exit 0
else
  echo "RESULTADO: $FAILS aserción(es) fallida(s)."
  exit 1
fi
