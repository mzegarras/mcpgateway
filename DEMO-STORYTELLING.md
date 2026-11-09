# Demo agentgateway — Storytelling

Guion narrativo para la PoC de **agentgateway como MCP gateway** de ManuBank.
Cada sección corresponde a un script de prueba: la **escena**, el **comando**, lo que
**ve la audiencia** y el **mensaje** que queda.

## Elenco

- **Ana** — analista de pagos. Roles: `pagos.read`, `pagos.write`, `pii.read`.
  Puede consultar, transferir (dentro de límite) y ver datos sensibles en claro.
- **Luis** — agente de soporte. Roles: `pagos.read`. **Sin** `pagos.write` ni `pii.read`.
  Puede consultar, pero no transferir ni ver datos sensibles.
- **El gateway** — el guardián entre los agentes/clientes y los MCP de ManuBank
  (`cuentas`, `pagos`). Nadie habla con un MCP directamente: todo pasa por aquí.

> Idea de fondo que se repite en cada historia: **el control vive en el gateway**, no
> en el cliente ni en cada MCP. Un solo punto donde se autentica, autoriza, limita,
> filtra, enmascara y audita.

Orden sugerido de la demo: **1 → 2 → 3 → 4 → 5** (de "lo permitido" a "lo que protegemos",
y cerrando con la **evidencia**: la auditoría). Ver `DEMO-DIAGRAMS.md` para los diagramas
de los escenarios de rate limit y PII.

---

## 1. `test.sh` — "Un día normal en la banca digital"

**Escena.** Ana abre su asistente para operar. Antes de tocar nada, tiene que
demostrar quién es: pide un token a Keycloak. Con ese token entra al gateway y el
gateway decide, regla por regla, qué puede hacer.

**Comando.**
```bash
./test.sh            # ana por defecto
```

**Lo que ve la audiencia (beats).**
1. **Identidad** — Keycloak emite el JWT; mostramos los claims (`preferred_username`,
   roles, grupos). "El gateway sabe *quién* es Ana, no solo que trae un token."
2. **Catálogo filtrado** — `tools/list` solo muestra lo que a Ana le corresponde.
   No existe un menú universal: cada quien ve su propio catálogo.
3. **Operaciones permitidas** — consulta saldo/movimientos, estado de pagos,
   y transfiere **S/ 100** (tiene `pagos.write`). Todo `200 OK`.
4. **El freno de negocio** — intenta transferir **S/ 9 000** y el gateway responde
   `403`: la regla dice `monto <= 5000`. No fue la app quien lo frenó: fue el gateway.

**Mensaje.**
> "Autenticación + autorización por tool **y por argumento**, en un solo sitio. La misma
> identidad habilita unas cosas y bloquea otras, con reglas declarativas."

---

## 2. `test-ratelimit.sh` — "El cajero que se desboca"

**Escena.** Algo —un script, un bug, un atacante con el token de Ana— empieza a
disparar transferencias en ráfaga. En la banca, eso es señal de fraude o abuso. ¿Aguanta
el perímetro?

**Comando.**
```bash
./test-ratelimit.sh          # ráfaga de 15 por tipo de request
```

**Lo que ve la audiencia (beats).**
1. **El handshake no se limita** — las `initialize` pasan todas. No castigamos lo inocente.
2. **Las consultas no se limitan** — ráfaga de `get_saldo`: todas pasan. Consultar es barato.
3. **La transferencia sí** — ráfaga de `transferir`: las primeras pasan y, superado el
   umbral (**10/min por usuario**), empiezan los `🚫 RATE-LIMITED`.
4. **Veredicto** — el script confirma: limitado **solo** `transferir`, no el resto.

**Mensaje.**
> "Cuota **global y exacta por usuario** (contadores en un RLS + Redis, no por instancia),
> aplicada **quirúrgicamente** solo a la operación sensible. El abuso se corta sin degradar
> la experiencia normal."

---

## 3. `test-tool-delete.sh` — "La herramienta que nunca debió existir"

**Escena.** El equipo de `cuentas` publicó, por error o por descuido, una herramienta
destructiva: `delete_account`. En un mundo sin gateway, cualquier agente con acceso al
MCP podría descubrirla y ejecutarla. Aquí no.

**Comando.**
```bash
./test-tool-delete.sh
```

**Lo que ve la audiencia (beats).**
1. **Invisible** — en `tools/list`, `delete_account` **no aparece**. El agente (y el LLM)
   nunca saben que existe; no se puede invocar lo que no se ve.
2. **Blindada** — aun llamándola a mano por su nombre exacto, el gateway responde `403`.
3. El script cierra con `RESULTADO: OK — 'delete_account' está correctamente filtrada`.

**Mensaje.**
> "**Tool filtering**: el gateway recorta la superficie de ataque. El MCP puede exponer de
> todo; lo que llega al agente es solo lo aprobado. Lo peligroso ni se anuncia ni se ejecuta."

---

## 4. `test-guardrail-pii.sh` — "El mismo dato, dos verdades"

**Escena.** Ana (backoffice, autorizada) y Luis (soporte) consultan **exactamente la misma
cuenta con la misma herramienta**. El dato trae un número de tarjeta completo (PAN). ¿Deben
ver lo mismo? No. Y la decisión no la toma la app: la toma un **guardrail de contenido
externo** al que el gateway le cuenta quién pregunta.

**Comando.**
```bash
./test-guardrail-pii.sh      # ana (claro) vs luis (enmascarado)
```

**Lo que ve la audiencia (beats).**
1. **Luis** pide el saldo → `tarjeta: ************6467`. El PAN sale **enmascarado**:
   solo los últimos 4.
2. **Ana** pide lo mismo → `tarjeta: 4539148803436467`. Lo ve **en claro**, porque su token
   trae `pii.read`.
3. **Por campo** — el `saldo` y la `cuenta` quedan intactos en ambos casos. Solo se redacta
   lo sensible.
4. (En los logs del guardrail se ve la decisión por usuario/rol: trazabilidad total.)

**Mensaje.**
> "El dato sensible **no sale del perímetro sin autorización**. Mismo tool, misma data,
> resultado distinto según el **contexto** del que pregunta — y cada des-enmascarado queda
> auditado. Aquí el guardrail soy yo (un servicio), pero mañana puede ser tu DLP corporativo."

---

## 5. Auditoría — "Si no quedó registrado, no pasó"

**Escena.** Termina la demo. Llega Cumplimiento (o el regulador) y pregunta lo de siempre:
*¿quién hizo qué, cuándo, y qué decidió el sistema?* En banca, cada decisión del perímetro
—permitir, denegar, limitar, enmascarar— tiene que quedar registrada y ser consultable.
Aquí no es un añadido: el gateway **ya audita todo lo de las 4 historias anteriores**.

**Dónde mirar.**
- Grafana → dashboard **"agentgateway audit"** (`http://localhost:3001`).
- O en vivo: `docker compose logs -f agentgateway`.

**Lo que ve la audiencia (beats).**
1. **Cada request es una línea de auditoría** con la decisión en `reason`
   (`allow` / `Authorization` / `RateLimit`) y los campos enriquecidos
   `audit_user`, `audit_tool`, `audit_target`, más `trace.id`/`span.id`.
2. **Reproducimos las historias y aparecen en el log**:
   - Historia 1 → `reason=allow ... audit_tool=transferir` y el intento de S/9 000 como
     `reason=Authorization` (denegado).
   - Historia 2 → ráfaga de `transferir` con `reason=RateLimit` para `audit_user=ana`.
   - Historia 3 → intento a `delete_account` rechazado.
   - Historia 4 → `audit_tool=get_saldo` para ana y para luis (y en el log del guardrail,
     la decisión claro vs enmascarado por rol).
3. **Cómo llega ahí** (sin Promtail ni socket de Docker): el gateway empuja los access logs
   por **OTLP/gRPC** a un **OTel Collector**, que los reenvía a **Loki** (OTLP/HTTP), y
   Grafana los consulta. Las **métricas** van por separado: Prometheus scrapea `/metrics`.

**Mensaje.**
> "Un **punto único de observabilidad**: toda decisión de seguridad —quién, qué tool, qué
> target, permitido/denegado/limitado/enmascarado— queda auditada y correlacionable por
> `trace.id`. Gobierno y trazabilidad de regalo, no como proyecto aparte."

> Diagrama del pipeline de auditoría en `DEMO-DIAGRAMS.md` (sección 0).

---

## Cierre (el hilo conductor)

A lo largo de las cuatro historias, el gateway hizo de **punto único de control**:

| Historia | Guardrail demostrado |
|---|---|
| 1 · Día normal | AuthN (Keycloak) + AuthZ por **rol** y por **argumento** |
| 2 · Cajero desbocado | **Rate limit** global por usuario, quirúrgico |
| 3 · Herramienta prohibida | **Tool filtering** (reduce superficie de ataque) |
| 4 · Mismo dato, dos verdades | **Guardrail de contenido** (PII) externo y contextual |
| 5 · Si no quedó registrado, no pasó | **Auditoría** (access logs → OTLP → Loki → Grafana) |

> Las historias 1–4 son las **decisiones**; la 5 es la **evidencia**: cada allow/deny/
> ratelimit/mask se exporta por OTLP a Loki y se ve en Grafana, correlacionable por `trace.id`.
> Un solo lugar para gobernar —y demostrar— *quién*, *qué*, *cuánto* y *con qué dato*.
