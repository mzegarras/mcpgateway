#!/usr/bin/env python3
# Servidor de guardrail externo (ExtMcp) para agentgateway.
# Implementa el proto agentgateway.dev.ext_mcp.ExtMcp (gRPC/h2c):
#   - CheckRequest : no toca la request (pass).
#   - CheckResponse: enmascara PII (p. ej. DNI, nº de tarjeta) en el resultado de las
#                    tools, SALVO que el llamante traiga el rol 'pii.read' en su JWT.
#
# El contexto de identidad llega en metadata_context, que el gateway rellena con las
# expresiones CEL declaradas en config.yaml (mcpGuardrails.processors[].metadata),
# p.ej. {roles: jwt.realm_access.roles, user: jwt.preferred_username}.
#
# Caso 3 de la demo: "mismo dato, mismo tool; claro para unos, enmascarado para otros",
# decidido por CONTEXTO (el rol del token), con enmascarado POR CAMPO.
import json
import re
from concurrent import futures

import grpc
from google.protobuf.json_format import MessageToDict

import ext_mcp_pb2 as pb
import ext_mcp_pb2_grpc as pbg

ROLE_CLEAR = "pii.read"  # rol que autoriza ver el dato en claro (des-enmascarado)

# Enmascara cualquier dígito que tenga >=4 dígitos por delante => deja ver solo los
# últimos 4 de una secuencia numérica larga (DNI, PAN, etc.). No toca importes "1250.75"
# ni fechas "2026-11-01" (no tienen 4 dígitos consecutivos por delante).
_LONG_NUM = re.compile(r"\d(?=\d{4})")


def _mask_text(s: str) -> str:
    return _LONG_NUM.sub("*", s)


def _mask(obj):
    if isinstance(obj, str):
        return _mask_text(obj)
    if isinstance(obj, list):
        return [_mask(x) for x in obj]
    if isinstance(obj, dict):
        return {k: _mask(v) for k, v in obj.items()}
    return obj


class ExtMcp(pbg.ExtMcpServicer):
    def CheckRequest(self, request, context):
        # No modificamos la request en esta demo.
        res = pb.McpRequestResult()
        getattr(res, "pass").CopyFrom(pb.Pass())
        return res

    def CheckResponse(self, request, context):
        md = MessageToDict(request.metadata_context) if request.metadata_context else {}
        roles = md.get("roles") or []
        user = md.get("user") or "?"

        res = pb.McpResponseResult()

        if ROLE_CLEAR in roles:
            print(f"[guardrail] user={user} roles={roles} -> CLARO (tiene {ROLE_CLEAR})", flush=True)
            getattr(res, "pass").CopyFrom(pb.Pass())
            return res

        try:
            data = json.loads(request.mcp_response)
        except Exception as e:  # cuerpo no-JSON: no tocar
            print(f"[guardrail] user={user} resultado no-JSON ({e}) -> pass", flush=True)
            getattr(res, "pass").CopyFrom(pb.Pass())
            return res

        masked = _mask(data)
        print(f"[guardrail] user={user} roles={roles} -> ENMASCARADO", flush=True)
        res.mutated = json.dumps(masked).encode()
        return res


def main():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    pbg.add_ExtMcpServicer_to_server(ExtMcp(), server)
    server.add_insecure_port("0.0.0.0:4445")  # gRPC en claro (h2c), como espera el gateway
    print("[guardrail] ExtMcp escuchando en 0.0.0.0:4445", flush=True)
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    main()
