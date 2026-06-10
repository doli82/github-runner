FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_ROOT=/actions-runner \
    RUNNER_WORKDIR=/_work \
    GITHUB_API_URL=https://api.github.com \
    DOCKER_BUILDKIT=1 \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_NOLOGO=1

# Pin para builds reprodutíveis: --build-arg RUNNER_VERSION=2.x.y
# Vazio = busca a última release no momento do build.
ARG RUNNER_VERSION=""
ARG TARGETARCH=amd64

# Tooling base + Docker CLI/buildx (Docker-out-of-Docker: sem daemon na imagem)
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg jq git unzip bash gosu procps iputils-ping; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    useradd -m -s /bin/bash runner; \
    rm -rf /var/lib/apt/lists/*

WORKDIR ${RUNNER_ROOT}

# Baixa + extrai o runner e instala as deps de SO pelo script oficial
# (mantém libicu/libssl/libkrb5 alinhados à versão do runner).
RUN set -eux; \
    arch="$([ "${TARGETARCH}" = "arm64" ] && echo arm64 || echo x64)"; \
    version="${RUNNER_VERSION}"; \
    if [ -z "$version" ]; then \
        version="$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "${GITHUB_API_URL}/repos/actions/runner/releases/latest" | jq -r '.tag_name' | sed 's/^v//')"; \
    fi; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o /tmp/runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-${arch}-${version}.tar.gz"; \
    tar xzf /tmp/runner.tar.gz -C "${RUNNER_ROOT}"; \
    rm -f /tmp/runner.tar.gz; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner "${RUNNER_ROOT}"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Detecta runner morto para a orquestração reiniciar o container.
# start-period folgado para cobrir config com retry de rede.
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s --retries=3 \
    CMD pgrep -f Runner.Listener >/dev/null || exit 1

# Sem VOLUME de propósito: monte um volume NOMEADO para /_work pela
# orquestração (controle de cache e sem volumes anônimos órfãos).

ENTRYPOINT ["/entrypoint.sh"]