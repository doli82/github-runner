FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_ROOT=/actions-runner
ENV RUNNER_WORKDIR=/_work
ENV GITHUB_API_URL=https://api.github.com

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        jq \
        git \
        iputils-ping \
        libssl3 \
        libicu-dev \
        libkrb5-3 \
        libxml2 \
        libcurl4 \
        procps \
        unzip \
        bash \
        gosu \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash runner

WORKDIR ${RUNNER_ROOT}

RUN set -eux; \
    LATEST=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name); \
    VERSION=$(echo $LATEST | sed 's/^v//'); \
    curl -fsSL -o /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/${LATEST}/actions-runner-linux-x64-${VERSION}.tar.gz"; \
    tar xzf /tmp/runner.tar.gz -C ${RUNNER_ROOT}; \
    rm -f /tmp/runner.tar.gz \
    && chown -R runner:runner ${RUNNER_ROOT}

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/_work"]

ENTRYPOINT ["/entrypoint.sh"]
