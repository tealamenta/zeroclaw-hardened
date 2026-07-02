# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Hardened image for the ZeroClaw coding agent.
# The image KEEPS a shell on purpose: a real coding agent needs shell/file/HTTP
# tools, so the threat model assumes the agent CAN execute commands. Containment
# is enforced at RUNTIME (read-only root + :ro config mounts + cap-drop + seccomp
# + egress policy), not by crippling the binary inside the image.
# ---------------------------------------------------------------------------
ARG DEBIAN_TAG=bookworm-slim

# ============================ Stage 1 : fetch ==============================
FROM debian:${DEBIAN_TAG} AS fetch
# Pin the release you actually tested. Verify the asset name on the releases page:
#   https://github.com/zeroclaw-labs/zeroclaw/releases
ARG ZEROCLAW_URL=https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.8.2/zeroclaw-aarch64-unknown-linux-gnu.tar.gz
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates tar; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /out; \
    curl -fsSL "${ZEROCLAW_URL}" -o /tmp/zc.tar.gz; \
    tar -xzf /tmp/zc.tar.gz -C /tmp; \
    BIN="$(find /tmp -maxdepth 4 -type f -name zeroclaw | head -n1)"; \
    test -n "$BIN"; \
    install -m 0755 "$BIN" /out/zeroclaw; \
    /out/zeroclaw --version || true

# ============================ Stage 2 : runtime ============================
FROM debian:${DEBIAN_TAG} AS runtime
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 10001 zeroclaw; \
    useradd  -u 10001 -g 10001 -m -s /bin/sh zeroclaw; \
    mkdir -p /home/zeroclaw/.zeroclaw/workspace \
             /home/zeroclaw/.zeroclaw/skills \
             /home/zeroclaw/.zeroclaw/memory \
             /home/zeroclaw/.zeroclaw/cache \
             /home/zeroclaw/.zeroclaw/logs; \
    chown -R zeroclaw:zeroclaw /home/zeroclaw

COPY --from=fetch /out/zeroclaw /usr/local/bin/zeroclaw

USER 10001:10001
WORKDIR /home/zeroclaw
ENV HOME=/home/zeroclaw \
    ZEROCLAW_HOME=/home/zeroclaw/.zeroclaw \
    OLLAMA_HOST=http://ollama:11434

# Keep the container alive so the containment demo can exec the "compromised agent"
# actions into it. Run a real coding task with:
#   docker compose exec agent zeroclaw agent -a coding -m "summarise the repo"
CMD ["sleep", "infinity"]
