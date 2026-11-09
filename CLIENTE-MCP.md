# Conectar un cliente MCP al gateway (Claude Desktop / VS Code)

> Guía práctica para conectar Claude Desktop o VS Code al gateway MCP de esta PoC
> (`http://localhost:3000/mcp`), autenticando contra Keycloak (realm `manubank`).
>
> **Regla de oro:** usa `mcp-remote` por **stdio** con el client **fijado**
> (`--static-oauth-client-info`). Evita la conexión HTTP nativa del cliente,
> que intenta **DCR** (registro dinámico) y falla contra este Keycloak.

## 1. Por qué NO usar la conexión HTTP nativa

Si configuras el servidor como `type: http` apuntando directo a `:3000/mcp`, el cliente
(VS Code o Claude) intenta hacer **OAuth + Dynamic Client Registration (DCR)** contra Keycloak.
Este realm **no expone DCR**, así que se rompe con alguno de estos síntomas:

| Síntoma | Causa |
|---|---|
| Diálogo pidiendo **Client ID** y **Client secret** | El cliente no pudo hacer DCR y pide registrar el client a mano |
| `User did not provide client details` + `401 JWT token required` | No obtuvo token → el gateway rechaza (correcto) |
| Navegador: **"We are sorry… Client not found."** | La petición llegó a Keycloak con un `client_id` que el realm no conoce (normalmente uno viejo cacheado) |

> Ver `SECURITY.md §3` para el trade-off DCR vs. client fijado.

## 2. Configuración correcta (client público + PKCE)

El client `mcp-gateway` del realm es **público** (`publicClient: true`, sin secreto) y usa **PKCE**.
`mcp-remote` maneja ese flujo solo y abre el navegador para el login.

### Claude Desktop

Archivo: `~/Library/Application Support/Claude/claude_desktop_config.json`
(o en la app: **Settings → Developer → Edit Config**). Clave raíz: `mcpServers`.

```json
{
  "mcpServers": {
    "agw": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "http://localhost:3000/mcp",
        "--static-oauth-client-info", "{\"client_id\":\"mcp-gateway\"}"
      ]
    }
  }
}
```

### VS Code

Archivo por workspace: `.vscode/mcp.json` · o a nivel usuario:
Command Palette (`⇧⌘P`) → **"MCP: Open User Configuration"**.
Clave raíz: `servers` (¡no `mcpServers`!) y campo `type`.

```json
{
  "servers": {
    "agw": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "http://localhost:3000/mcp",
        "--static-oauth-client-info", "{\"client_id\":\"mcp-gateway\"}"
      ]
    }
  }
}
```

> ⚠️ Revisa que **no** exista otra entrada del mismo servidor con `type: http` en la config
> de usuario de VS Code (`~/Library/Application Support/Code/User/mcp.json`); si la hay, bórrala
> o cámbiala a `stdio` — esa es la que dispara el diálogo de Client ID/secret.

## 3. Si el cliente te pide Client ID / Secret (camino HTTP)

Solo ocurre con `type: http`. Si decides responder el diálogo, para el client público:

- **Client ID:** `mcp-gateway`
- **Client Secret / credentials:** **déjalo VACÍO** (es público, usa PKCE)

Si el cliente **obliga** a un secreto no vacío → no sirve con client público: usa el `stdio` de arriba.

## 4. Arreglar "Client not found" / logins atascados

El `"Client not found"` o un login que no avanza casi siempre es **estado OAuth viejo cacheado**
por `mcp-remote` (p. ej. de un intento DCR previo). Limpia y reinicia:

```bash
# 1) Borrar el caché de tokens/clientes de mcp-remote
rm -rf ~/.mcp-auth/mcp-remote-*

# 2) Reiniciar el cliente MCP
#    - Claude Desktop: Quit total y reabrir
osascript -e 'quit app "Claude"'
#    - VS Code: Command Palette → "MCP: List Servers" → agw → Restart
```

La primera conexión abrirá el **navegador** hacia Keycloak. Entra con un usuario del realm:

| Usuario | Password | Roles | Puede |
|---|---|---|---|
| `ana`  | `ana`  | `pagos.read`, `pagos.write` | consultar cuentas/pagos y **transferir** (monto ≤ 5000) |
| `luis` | `luis` | `pagos.read` | consultar cuentas/pagos; **no** transferir |

## 5. Verificar que el backend está sano (aislar cliente vs. gateway)

Antes de culpar al cliente, confirma que el camino con token funciona:

```bash
# Gateway y dependencias arriba
docker compose ps

# Keycloak emite token para el client mcp-gateway (debe dar HTTP 200)
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:8080/realms/manubank/protocol/openid-connect/token \
  -d grant_type=password -d client_id=mcp-gateway -d username=ana -d password=ana

# Flujo extremo a extremo Keycloak -> gateway -> MCPs
./test.sh ana ana
```

- `test.sh` pasa pero el cliente no → el problema es el OAuth del cliente (config + limpiar caché + reiniciar).
- `test.sh` falla → revisa `docker compose logs agentgateway` y `keycloak`.

## 6. Dónde ver logs del cliente

- **VS Code:** Command Palette → **"MCP: List Servers"** → `agw` → **Show Output**.
- **Claude Desktop:** `~/Library/Logs/Claude/mcp-server-agw.log` (o `mcp.log`).

- Usuario: /Users/manuel/Library/Application Support/Code/User/mcp.json
- Workspace: /Users/manuel/Downloads/agw-poc/.vscode/mcp.json