from fastmcp import FastMCP

mcp = FastMCP("pagos")

@mcp.tool()
def get_estado(id_pago: str) -> dict:
    """Estado de un pago."""
    return {"id": id_pago, "estado": "PROCESADO"}

@mcp.tool()
def transferir(origen: str, destino: str, monto: float) -> dict:
    """Transferencia entre cuentas. El gateway limita monto y rol."""
    return {"ok": True, "origen": origen, "destino": destino, "monto": monto}

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=8000)
