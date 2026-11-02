# Один образ для обох Python-сервісів (generator і auth), команду задає docker-compose.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py .
ENV PYTHONUNBUFFERED=1
