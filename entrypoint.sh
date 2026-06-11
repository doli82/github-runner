#!/usr/bin/env bash
set -euo pipefail

cd /actions-runner

# --- Permissão do socket do Docker (Docker-out-of-Docker) ---
if [ -S /var/run/docker.sock ]; then
  DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
  if [ "$DOCKER_GID" != "0" ]; then
    group_name="$(getent group "$DOCKER_GID" | cut -d: -f1 || true)"
    if [ -z "$group_name" ]; then
      group_name=docker-host
      groupadd -g "$DOCKER_GID" "$group_name"
    fi
    usermod -aG "$group_name" runner
  fi
fi

# --- Dono do work dir: só ajusta o ponto de montagem, não recursivo no cache ---
if [ -d /_work ] && [ "$(stat -c '%U' /_work 2>/dev/null)" != "runner" ]; then
  chown runner:runner /_work
fi

# --- Entradas ---
# Suporte a *_FILE (Docker/Swarm secrets): se definido, lê o valor do arquivo.
if [ -n "${GITHUB_PAT_FILE:-}" ] && [ -r "${GITHUB_PAT_FILE}" ]; then
  GITHUB_PAT="$(cat "${GITHUB_PAT_FILE}")"
fi

RUNNER_URL="${RUNNER_URL:-${REPO_URL:-}}"
GITHUB_PAT="${GITHUB_PAT:-${PAT_TOKEN:-}}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-/_work}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-false}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"

[ -n "$RUNNER_URL" ]  || { echo "ERROR: RUNNER_URL/REPO_URL obrigatório"; exit 1; }
[ -n "$GITHUB_PAT" ]  || { echo "ERROR: GITHUB_PAT/PAT_TOKEN obrigatório"; exit 1; }

parse_urls() {
  local host path
  host="$(awk -F/ '{print $3}' <<<"$RUNNER_URL")"
  [ "$host" = "github.com" ] || { echo "ERROR: só URLs github.com são suportadas"; exit 1; }
  path="$(sed -E 's#https://github.com/##; s#/$##' <<<"$RUNNER_URL")"
  if [[ "$path" =~ ^([^/]+)/([^/]+)$ ]]; then
    API_PATH="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$path" =~ ^([^/]+)$ ]]; then
    API_PATH="orgs/${BASH_REMATCH[1]}"
  else
    echo "ERROR: RUNNER_URL deve ser URL de repo ou org"; exit 1
  fi
  REGISTRATION_API="${GITHUB_API_URL}/${API_PATH}/actions/runners/registration-token"
  REMOVE_API="${GITHUB_API_URL}/${API_PATH}/actions/runners/remove-token"
}

request_token() {
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 10 -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GITHUB_PAT}" \
    "$1" | jq -r '.token'
}

configure_runner() {
  local token
  token="$(request_token "$REGISTRATION_API")"
  [ -n "$token" ] && [ "$token" != "null" ] || { echo "ERROR: registration token vazio"; return 1; }

  local extra=()
  [ "$RUNNER_EPHEMERAL" = "true" ] && extra+=(--ephemeral)

  gosu runner ./config.sh --unattended \
    --url "$RUNNER_URL" \
    --token "$token" \
    --name "$RUNNER_NAME" \
    --work "$RUNNER_WORKDIR" \
    --labels "$RUNNER_LABELS" \
    --runnergroup "$RUNNER_GROUP" \
    --replace \
    --disableupdate \
    "${extra[@]}"
}

remove_runner() {
  [ -f .runner ] || return 0
  local token
  token="$(request_token "$REMOVE_API")" || return 0
  [ -n "$token" ] && [ "$token" != "null" ] || return 0
  gosu runner ./config.sh remove --token "$token" || true
}

# Espera o job em andamento terminar. Runner.Worker é o processo do job:
# enquanto ele existir, há um job rodando e NÃO podemos sinalizar o listener
# (TERM no Runner.Listener cancela o job no meio — era isso que matava os
# deploys). Mesma estratégia do actions-runner-controller oficial.
wait_for_job() {
  if pgrep -f Runner.Worker >/dev/null 2>&1; then
    echo ">> Job em andamento: aguardando finalizar antes de parar o runner..."
    while pgrep -f Runner.Worker >/dev/null 2>&1; do
      sleep 5
    done
    echo ">> Job finalizado."
  fi
}

# NOTA: o shutdown abaixo espera o job atual terminar após o SIGTERM.
# Garanta na orquestração um timeout generoso ou o Docker mata em 10s:
#   docker run --stop-timeout 3600   /   compose: stop_grace_period: 1h
_stopped=0
graceful_stop() {
  [ "$_stopped" = "1" ] && return
  _stopped=1
  echo ">> Sinal de parada recebido."
  wait_for_job
  # Sem job rodando: ephemeral já saiu sozinho após o job; persistente está
  # ocioso e pode receber TERM sem derrubar nada.
  if [ -n "${RUNNER_PID:-}" ] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  # Ephemeral se desregistra sozinho no GitHub após o job; tentar remover um
  # runner ocupado só gera "cannot be deleted". Só removemos os persistentes.
  [ "$RUNNER_EPHEMERAL" = "true" ] || remove_runner
  exit 0
}
trap graceful_stop TERM INT

parse_urls

# Ephemeral sempre reconfigura (registro é descartado após cada job).
if [ "$RUNNER_EPHEMERAL" = "true" ] || [ ! -f .runner ]; then
  rm -f .runner .credentials .credentials_rsaparams 2>/dev/null || true
  # Se o registro falhar (API inacessível), espera antes de sair: sem isto o
  # restart loop martela api.github.com e dispara abuse mitigation do GitHub.
  configure_runner || { echo "ERROR: registro falhou; aguardando 60s antes de sair"; sleep 60; exit 1; }
fi

echo ">> Iniciando GitHub Actions Runner: $RUNNER_NAME"
gosu runner ./run.sh &
RUNNER_PID=$!
wait "$RUNNER_PID"
code=$?

# Saída inesperada (não foi sinal): desregistra para não deixar runner fantasma.
# A orquestração reinicia o container (restart policy), que reconfigura.
# Ephemeral já se removeu no GitHub após o job; não tentar de novo.
[ "$RUNNER_EPHEMERAL" = "true" ] || remove_runner
exit "$code"