# Demo agentgateway — Diagramas

Diagramas de apoyo para los escenarios de **Rate limit** y **PII (guardrail)**, más la
**auditoría** que los acompaña a ambos. En Mermaid (se renderizan en GitHub/IDE).

Convención de red: el gateway comparte el *netns* de Keycloak, por eso `localhost:8080`
(Keycloak) lo alcanza directo, y a `ratelimit:8081`, `ext-mcp-guardrail:4445` y
`otel-collector:4317` los resuelve por DNS de la red por defecto.

---

## 0. Auditoría — el hilo que atraviesa todo

Cada request que pasa por el gateway produce **un access log** con la decisión
(`reason` = allow / Authorization / RateLimit) y campos enriquecidos (`audit_user`,
`audit_tool`, `audit_target`) + `trace.id`/`span.id`. Ese registro se exporta y termina
consultable en Grafana. **No hay Promtail ni socket de Docker**: el gateway empuja por OTLP.

```mermaid
flowchart LR
    subgraph GW["agentgateway"]
      AL["accessLog + tracing\nreason, audit_user,\naudit_tool, audit_target,\ntrace.id / span.id"]
    end
    AL -- "OTLP/gRPC :4317" --> COL["otel-collector"]
    COL -- "OTLP/HTTP /otlp/v1/logs" --> LOKI[("Loki")]
    COL -- "traces" --> DBG["debug exporter\n(sin backend)"]
    LOKI --> GRAF["Grafana\ndashboard 'agentgateway audit'"]
    PROM["Prometheus"] -- "scrape :15020/metrics" --> GW
    PROM --> GRAF
```

Regla mnemotécnica: **métricas** = Prometheus (cuánto); **auditoría** = access logs → Loki
(qué/quién/por qué); **trazas** = OTLP → collector (correlación por `trace.id`).

---

## 1. Rate limit — "El cajero que se desboca"

Cuota **global por usuario** sobre `transferir`. Los contadores **no** viven en el gateway:
viven en el RLS (`envoyproxy/ratelimit`) respaldado por **Redis**, por eso la cuota es la
misma aunque haya N réplicas de gateway. `initialize` y otras tools **no** se limitan
(el `conditional` solo matchea `transferir`).

```mermaid
sequenceDiagram
    autonumber
    participant C as Cliente / Agente
    participant G as agentgateway
    participant R as RLS (ratelimit:8081)
    participant RD as Redis
    participant P as mcp-pagos
    participant O as otel-collector → Loki

    C->>G: tools/call "transferir" (Bearer JWT de ana)
    Note over G: AuthN (JWT) + AuthZ OK<br/>(pagos.write, monto<=5000)
    G->>R: ShouldRateLimit(domain=agentgateway,<br/>descriptor user=ana)
    R->>RD: INCR contador(user=ana, ventana=1min)
    RD-->>R: conteo actual
    alt dentro de la cuota (<=10/min)
        R-->>G: OK
        G->>P: tools/call "transferir"
        P-->>G: resultado {ok:true}
        G-->>C: 200 resultado
        G-)O: access log reason=allow,<br/>audit_user=ana, audit_tool=transferir
    else cuota superada (>10/min)
        R-->>G: OVER_LIMIT
        G-->>C: error MCP "rate limit exceeded"
        G-)O: access log reason=RateLimit,<br/>audit_user=ana, audit_tool=transferir
    end
    Note over O: auditable en Grafana:<br/>quién, qué tool, permitido vs limitado
```

Puntos para narrar:
- El gateway **pregunta** al RLS (gRPC Envoy RLS); el RLS **cuenta** en Redis.
- `failureMode: failOpen` → si el RLS cae, la transferencia **pasa** (no se corta el negocio).
- Ambos desenlaces (OK y OVER_LIMIT) **se auditan** con el mismo `audit_user`/`audit_tool`.

---

## 2. PII — "El mismo dato, dos verdades"

El gateway envía la **respuesta** de cada `tools/call` a un guardrail externo (gRPC `ExtMcp`),
junto con la **identidad** del llamante (claims por CEL en `metadata`). El guardrail decide
en claro vs enmascarado **por contexto** y reescribe el resultado **por campo**.

```mermaid
sequenceDiagram
    autonumber
    participant C as Cliente (ana / luis)
    participant G as agentgateway
    participant M as mcp-cuentas
    participant X as ext-mcp-guardrail (ExtMcp :4445)
    participant O as otel-collector → Loki

    C->>G: tools/call "get_cliente" (Bearer JWT)
    Note over G: AuthN + AuthZ OK<br/>(cualquier autenticado consulta)
    G->>M: tools/call "get_cliente"
    M-->>G: result { id, nombre, dni: DNI completo }
    G->>X: CheckResponse(mcp_response=result,<br/>metadata={user, roles})
    alt roles contiene pii.read (ana)
        X-->>G: Pass (sin cambios)
        G-->>C: dni = 45678912  (EN CLARO)
    else sin pii.read (luis)
        Note over X: enmascara DNI por campo<br/>(nombre/id intactos)
        X-->>G: mutated { dni: ****8912 }
        G-->>C: dni = ****8912  (ENMASCARADO)
    end
    G-)O: access log audit_user, audit_tool=get_cliente
    Note over O: cada des-enmascarado queda trazado
```

Puntos para narrar:
- El dato sensible **nunca sale del perímetro** sin autorización; la decisión la toma el
  guardrail, no la app ni el MCP.
- `failureMode: failClosed` → si el guardrail cae, la respuesta **se rechaza** (no se filtra PII).
- El enmascarado es **por campo** (solo `dni`), y es **agnóstico al esquema** (recorre el
  JSON que venga). Un solo guardrail sirve a todo el gateway y ramifica por MCP si hace falta.
