FROM python:3.12-slim
RUN pip install --no-cache-dir "fastmcp>=2.10"
WORKDIR /app
COPY server.py .
EXPOSE 8000
CMD ["python", "server.py"]
