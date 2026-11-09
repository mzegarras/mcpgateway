from fastmcp import FastMCP

mcp = FastMCP("cuentas")

@mcp.tool()
def get_saldo(cuenta: str) -> dict:
    """Saldo de una cuenta."""
    # 'tarjeta' trae el PAN completo a propósito: el guardrail externo lo enmascara
    # salvo que el llamante tenga el rol 'pii.read'.
    return {"cuenta": cuenta, "saldo": 1250.75, "moneda": "PEN", "tarjeta": "4539148803436467"}

@mcp.tool()
def get_movimientos(cuenta: str, dias: int = 30) -> list[dict]:
    """Últimos movimientos."""
    return [{"fecha": "2026-11-01", "monto": -45.0, "glosa": "Pago TC 4539148803436467"}]

@mcp.tool()
def delete_account(cuenta: str) -> dict:
    """PELIGROSA: elimina una cuenta. El MCP la expone, pero el gateway la FILTRA:
    no aparece en tools/list y no se puede invocar (demo de tool filtering)."""
    return {"cuenta": cuenta, "deleted": True}

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
