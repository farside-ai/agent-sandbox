# Tiny allowlisting HTTP/HTTPS forward proxy. The sandbox sits on an `internal`
# Docker network with no route to the internet; this proxy is its only way out,
# and it only forwards CONNECT/requests to allowlisted hosts (default-deny).
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends tinyproxy \
    && rm -rf /var/lib/apt/lists/*

COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY filter /etc/tinyproxy/filter

EXPOSE 8888
# -d: run in foreground so Docker manages the process/logs.
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
