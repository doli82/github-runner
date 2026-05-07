#!/usr/bin/env bash
set -euo pipefail

# Configure Docker socket permissions if present
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)
    if [ "$DOCKER_GID" != "0" ]; then
        groupadd -g "$DOCKER_GID" docker 2>/dev/null || true
        usermod -a -G docker runner
    fi
fi

# Ensure work directory is accessible by runner
if [ -d /_work ]; then
    chown -R runner:runner /_work
fi

cd /actions-runner

RUNNER_URL=${RUNNER_URL:-${REPO_URL:-}}
GITHUB_PAT=${GITHUB_PAT:-${PAT_TOKEN:-}}
RUNNER_NAME=${RUNNER_NAME:-$(hostname)}
RUNNER_WORKDIR=${RUNNER_WORKDIR:-/_work}
RUNNER_LABELS=${RUNNER_LABELS:-self-hosted,Linux}
RUNNER_GROUP=${RUNNER_GROUP:-Default}

if [ -z "$RUNNER_URL" ]; then
  echo "ERROR: RUNNER_URL or REPO_URL must be set"
  exit 1
fi

if [ -z "$GITHUB_PAT" ]; then
  echo "ERROR: GITHUB_PAT or PAT_TOKEN must be set"
  exit 1
fi

parse_urls() {
  local url="$RUNNER_URL"
  local host
  host=$(echo "$url" | awk -F/ '{print $3}')

  if [[ "$host" != "github.com" ]]; then
    echo "ERROR: only github.com URLs are supported by this image right now"
    exit 1
  fi

  local path
  path=$(echo "$url" | sed -E 's#https://github.com/##; s#/$##')

  if [[ "$path" =~ ^([^/]+)/([^/]+)$ ]]; then
    API_PATH="repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$path" =~ ^([^/]+)$ ]]; then
    API_PATH="orgs/${BASH_REMATCH[1]}"
  else
    echo "ERROR: RUNNER_URL must be a repository or organization URL"
    exit 1
  fi

  REGISTRATION_API="${GITHUB_API_URL}/${API_PATH}/actions/runners/registration-token"
  REMOVE_API="${GITHUB_API_URL}/${API_PATH}/actions/runners/remove-token"
}

request_token() {
  local api_url="$1"
  local response
  response=$(curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: token ${GITHUB_PAT}" \
    "$api_url")
  echo "$response" | jq -r .token
}

configure_runner() {
  echo "Configuring GitHub Actions Runner for $RUNNER_URL"
  local token
  token=$(request_token "$REGISTRATION_API")
  gosu runner ./config.sh --unattended \
    --url "$RUNNER_URL" \
    --token "$token" \
    --name "$RUNNER_NAME" \
    --work "$RUNNER_WORKDIR" \
    --labels "$RUNNER_LABELS" \
    --replace \
    --disableupdate
}

remove_runner() {
  if [ ! -f .runner ]; then
    return
  fi

  echo "Removing GitHub Actions Runner registration"
  local token
  token=$(request_token "$REMOVE_API") || return
  gosu runner ./config.sh remove --unattended --token "$token" || true
}

cleanup() {
  echo "Shutting down runner"
  if [ -n "${TOKEN_RENEWER_PID:-}" ]; then
    kill "$TOKEN_RENEWER_PID" 2>/dev/null || true
  fi
  remove_runner
  exit 0
}

token_renewer() {
  # Renewal loop - check every 24 hours
  local RENEWAL_INTERVAL=86400  # 24 hours in seconds
  
  while true; do
    sleep "$RENEWAL_INTERVAL"
    
    if [ ! -f .runner ]; then
      echo "Runner not registered, skipping renewal"
      continue
    fi
    
    echo "Renewing runner token"
    local new_token
    new_token=$(request_token "$REGISTRATION_API")
    
    if [ -z "$new_token" ]; then
      echo "Failed to get renewal token, will retry on next cycle"
      continue
    fi
    
    # Update the runner token by re-configuring
    gosu runner ./config.sh --unattended \
      --url "$RUNNER_URL" \
      --token "$new_token" \
      --name "$RUNNER_NAME" \
      --work "$RUNNER_WORKDIR" \
      --labels "$RUNNER_LABELS" \
      --replace \
      --disableupdate || echo "Token renewal failed, will retry on next cycle"
  done
}

trap cleanup TERM INT EXIT
parse_urls

# Start token renewal in background
token_renewer &
TOKEN_RENEWER_PID=$!

while true; do
  if [ ! -f .runner ]; then
    configure_runner
  fi

  echo "Starting GitHub Actions Runner"
  gosu runner ./run.sh &
  RUNNER_PID=$!

  wait "$RUNNER_PID"
  EXIT_CODE=$?

  if [ $EXIT_CODE -ne 0 ]; then
    echo "Runner stopped with exit code $EXIT_CODE, restarting in 5 seconds"
    sleep 5
    rm -rf .runner .credentials
  else
    echo "Runner finished, restarting immediately for next job"
  fi
done
