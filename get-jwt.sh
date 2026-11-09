#!/usr/bin/env bash
# Genera (obtiene) un JWT de acceso desde Keycloak para un usuario del realm 'manubank'.
# El gateway valida la firma contra el JWKS de Keycloak, por eso el token DEBE emitirlo
# Keycloak (un JWT firmado a mano sería rechazado).
#
# Uso:
#   ./get-jwt.sh [usuario] [password]      # por defecto ana/ana
#   ./get-jwt.sh ana -d                    # además imprime los claims decodificados (a stderr)
#   TOKEN=$(./get-jwt.sh ana)              # captura solo el token (stdout limpio)
#   curl -H "Authorization: Bearer $(./get-jwt.sh ana)" http://localhost:3000/mcp ...
set -u

KC=${KC_URL:-http://localhost:8080}
REALM=${KC_REALM:-manubank}
CLIENT=${KC_CLIENT:-mcp-gateway}

# Parseo simple: args posicionales (usuario, password) + flag -d/--decode
DECODE=0; POS=()
for a in "$@"; do
  case "$a" in
    -d|--decode) DECODE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) POS+=("$a") ;;
  esac
done
USER=${POS[0]:-ana}
PASS=${POS[1]:-$USER}

command -v jq >/dev/null || { echo "ERROR: falta jq (brew install jq)" >&2; exit 1; }

RESP=$(curl -s -w '\n%{http_code}' -X POST \
  "$KC/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id="$CLIENT" \
  -d username="$USER" -d password="$PASS")
CODE=$(tail -n1 <<<"$RESP"); BODY=$(sed '$d' <<<"$RESP")

if [[ "$CODE" != "200" ]]; then
  echo "ERROR: Keycloak respondió HTTP $CODE" >&2
  echo "$BODY" >&2
  exit 1
fi

TOKEN=$(jq -r '.access_token // empty' <<<"$BODY")
[[ -n "$TOKEN" ]] || { echo "ERROR: respuesta sin access_token" >&2; echo "$BODY" >&2; exit 1; }

# Claims decodificados a stderr (no contaminan el stdout capturable)
if [[ "$DECODE" -eq 1 ]]; then
  b64url_decode() { tr '_-' '/+' | awk '{l=length($0)%4; if(l) $0=$0 substr("===",1,4-l); print}' | base64 -d 2>/dev/null; }
  {
    echo "== header =="
    cut -d. -f1 <<<"$TOKEN" | b64url_decode | jq .
    echo "== payload (claims relevantes) =="
    cut -d. -f2 <<<"$TOKEN" | b64url_decode \
      | jq '{iss, aud, exp, preferred_username, roles: .realm_access.roles, groups}'
  } >&2
fi

# El token va a stdout para poder capturarlo o pipearlo
echo "$TOKEN"
