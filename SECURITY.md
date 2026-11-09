# Análisis de seguridad — PoC AgentGateway

> **Alcance:** este documento analiza el modelo de amenazas de *esta PoC* (Keycloak + agentgateway +
> MCP cuentas/pagos, todo en `localhost` vía Docker). **No es una configuración apta para producción.**
> Al final hay una checklist de endurecimiento.

## 1. Arquitectura y decisiones relevantes para seguridad

| Componente | Config actual | Nota de seguridad |
|---|---|---|
| Transporte | `http://` (sin TLS) | Tokens viajan en claro — sniffables en la red |
| Client Keycloak `mcp-gateway` | público + PKCE (S256) | Sin secreto; apropiado para cliente nativo/CLI |
| `directAccessGrantsEnabled` | `true` | Permite grant de password (útil en tests, superficie extra) |
| `redirectUris` | `http://localhost:*`, `http://127.0.0.1:*` | Amplio pero acotado a loopback |
| `webOrigins` | `*` | Permisivo (CORS) |
| Admin UI gateway (`:15000`) | bind `0.0.0.0`, **sin auth** | Expone `config_dump` / shutdown; solo PoC local |
| Session key del gateway | **no configurada** | MCP session IDs sin cifrar (warning en logs) |
| `offline_access` | habilitado para `ana` y `luis` | Genera **refresh tokens sin expiración** (ver §2) |
| Red | `agentgateway` comparte el netns de `keycloak` | Permite usar `localhost` como issuer único dentro y fuera del contenedor |

La autorización se hace **por tool** con reglas CEL en `agentgateway/config.yaml`, basadas en el
**usuario** (roles/grupos del JWT), no en el client:

```
cuentas get_*   -> cualquier usuario autenticado
pagos   get_*   -> rol pagos.read
pagos   transferir -> rol pagos.write  Y  monto <= 5000
```

## 2. Amenaza: robo del archivo de credenciales

El cliente MCP (`mcp-remote`) guarda los tokens en **texto plano**:

```
~/.mcp-auth/mcp-remote-v1/<hash>_tokens.json   (modo 600)
```

Contenido real observado en la PoC:

| Token | Vida | Riesgo |
|---|---|---|
| `access_token` | **300 s (5 min)** | Bajo por sí solo — caduca rápido |
| `refresh_token` | **`typ: Offline`, SIN expiración** | 🔴 **Crítico** |

### Impacto

El refresh token es **offline y no expira**. Como es un *bearer token* (no atado al dispositivo),
quien lo robe puede, **desde cualquier máquina** y de forma **indefinida** (hasta revocación explícita):

- Acuñar access tokens nuevos de `ana`.
- Ejecutar todo lo que `ana` puede: `cuentas_get_*`, `pagos_get_*` y **`transferir`** (tiene `pagos.write`).

El modo `600` solo protege frente a *otros usuarios* del equipo; **no** frente a malware corriendo
como el propio usuario.

### Mitigaciones ya presentes (defensa en profundidad)

- **La autorización CEL acota el *blast radius*:** aun con el token de `ana`, `transferir` está
  topado a **monto ≤ 5000** por llamada; un token de `luis` no puede transferir nada. El daño lo
  limita la *política*, no solo la identidad.
- **Auditoría:** el gateway registra `jwt.sub` + cada `tools/call` (target + tool) → rastro forense.

### Respuesta ante robo

En Keycloak (admin `http://localhost:8080`): **Realm `manubank` → Sessions → Logout** del usuario, o
revocar sus *offline sessions* / fijar un *not-before*. Eso invalida el refresh token de inmediato.

## 3. Trade-off: `mcp-remote` vs. conector nativo de Claude Desktop

El **punto 5** de endurecimiento ("guardar tokens en el llavero del SO, no en JSON plano") **no** es
algo que el gateway ni Keycloak puedan resolver: depende del **cliente MCP**.

- **`mcp-remote`** (setup actual) siempre escribe JSON plano y **no** usa el Keychain; no es configurable.
- **El conector nativo de Claude Desktop** gestiona el OAuth y almacena los tokens en el almacenamiento
  protegido del SO (en macOS, el Keychain). Pero hace **Dynamic Client Registration (DCR)**.

### Por qué DCR complica las cosas

Para que el conector nativo funcione, el token debe llevar `aud=mcp-gateway`. Hoy esa audiencia la
inyecta un *audience mapper* pegado **solo** al client `mcp-gateway`. Un client creado por DCR no lo
tendría → el gateway rechazaría su token. El "arreglo" sería mover el audience mapper a un
**client scope por defecto** del realm, pero eso tiene consecuencias:

- 🔴 **Debilita el aislamiento por audiencia:** *todos* los clients (incluidos los de DCR) recibirían
  `aud=mcp-gateway`. Un token emitido para otra app podría ser aceptado por el gateway.
- ⚠️ **Expone el `registration_endpoint` de DCR** como superficie de ataque — habría que cerrarlo
  (políticas de client registration / desactivar registro anónimo / exigir *initial access token*).

### Importante: audiencia ≠ autorización

DCR registra un **client**, no una **identidad de usuario**. Las reglas CEL autorizan por **roles del
usuario**, así que un client de DCR **por sí solo no da acceso a ninguna tool**: el atacante igual
tendría que autenticarse como un usuario real. Mover el audience mapper **no** baja la autorización
por tool; **sí** afloja la audiencia como control.

### Comparación

| Dimensión | **mcp-remote (actual)** | **Conector nativo + DCR** |
|---|---|---|
| Almacén de tokens | JSON plano ⚠️ | Keychain del SO ✅ |
| Usa DCR | **No** ✅ | Sí, hay que endurecerlo ⚠️ |
| Aislamiento de audiencia | Solo client `mcp-gateway` ✅ | Todos los clients ⚠️ |
| Requiere `npx` | Sí | No |

### Recomendación para la PoC

Mantener **`mcp-remote` con client fijado** (`--static-oauth-client-info {"client_id":"mcp-gateway"}`):
es más sólido en audiencia y no usa DCR. Su única debilidad —token en texto plano— es un riesgo
*local* que se mitiga con **FileVault** (cifrado de disco). El aislamiento de audiencia y el no-DCR
son defensas *arquitectónicas* que no conviene aflojar solo por el almacenamiento.

En producción, lo mejor de ambos mundos: conector nativo **+** DCR cerrado con *initial access token*
**+** tokens *sender-constrained* (**DPoP** o mTLS), que vuelve **irrelevante** el robo del archivo.

## 4. Checklist de endurecimiento para producción

- [ ] **TLS en todo** (`https://`) — hoy los tokens viajan en claro.
- [ ] **Quitar `offline_access`** si no se necesita acceso en background; usar refresh *online* atado a
      la sesión SSO con *idle timeout*.
- [ ] **Rotación de refresh tokens + "revoke on reuse"** (Keycloak) → refresh robado = un solo uso y
      el reuso es detectable.
- [ ] **Tokens sender-constrained (DPoP / mTLS)** → un bearer robado no sirve desde otra máquina.
- [ ] **Cerrar DCR** en Keycloak (políticas de client registration; desactivar registro anónimo) si se
      usa el conector nativo.
- [ ] **Proteger la Admin UI** del gateway (`:15000`) con auth / red privada; no exponer `config_dump`.
- [ ] **Configurar `SESSION_KEY`** en el gateway (cifra los MCP session IDs).
- [ ] **Bajar el tope de `transferir`** y exigir *step-up auth* (re-login) en operaciones sensibles.
- [ ] **Desactivar `directAccessGrants`** y acotar `webOrigins` / `redirectUris`.
- [ ] **Almacenar tokens cliente en el Keychain** (vía conector nativo) en lugar de JSON plano; entre
      tanto, cifrado de disco (FileVault).
- [ ] **Centralizar y retener los logs de auditoría** del gateway (`jwt.sub` + `tools/call`).
