FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY ext_mcp.proto .
# Genera los stubs gRPC a partir del proto (los well-known types vienen con grpcio-tools).
RUN python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. ext_mcp.proto
COPY server.py .
EXPOSE 4445
CMD ["python", "server.py"]
