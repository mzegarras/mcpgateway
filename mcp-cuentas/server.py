from fastmcp import FastMCP

mcp = FastMCP("cuentas")

@mcp.tool()
def get_saldo(cuenta: str) -> dict:
    """Saldo de una cuenta."""
    return {"cuenta": cuenta, "saldo": 1250.75, "moneda": "PEN"}

@mcp.tool()
def get_cliente(id: str) -> dict:
    """Datos del cliente."""
    # 'dni' es PII a propósito: el guardrail externo lo enmascara (deja solo los
    # últimos 4) salvo que el llamante tenga el rol 'pii.read'.
    return {"id": id, "nombre": "Maria Torres", "dni": "45678912"}

@mcp.tool()
def get_movimientos(cuenta: str, dias: int = 30) -> list[dict]:
    """Últimos movimientos."""
    return [{"fecha": "2026-11-01", "monto": -45.0, "glosa": "Compra con tarjeta"}]

@mcp.tool()
def delete_account(cuenta: str) -> dict:
    """PELIGROSA: elimina una cuenta. El MCP la expone, pero el gateway la FILTRA:
    no aparece en tools/list y no se puede invocar (demo de tool filtering)."""
    return {"cuenta": cuenta, "deleted": True}

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
