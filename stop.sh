#!/usr/bin/env bash
set -Eeuo pipefail

WORKER_IP="${WORKER_IP:-10.0.0.2}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-leanstral-vllm}"

HEAD_RAY_CONTAINER="${CONTAINER_PREFIX}-head"
WORKER_RAY_CONTAINER="${CONTAINER_PREFIX}-ray-worker"
OLD_HEAD_RAY_CONTAINER="${CONTAINER_PREFIX}-ray-head"
OLD_API_CONTAINER="${CONTAINER_PREFIX}-api"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${WORKER_IP}" "$@"
}

stop_local() {
  log "Stopping local vLLM/Ray containers"
  docker rm -f "${HEAD_RAY_CONTAINER}" "${OLD_HEAD_RAY_CONTAINER}" "${OLD_API_CONTAINER}" >/dev/null 2>&1 || true
}

stop_remote() {
  log "Stopping Ray worker on ${WORKER_IP}"
  remote "docker rm -f '${WORKER_RAY_CONTAINER}' >/dev/null 2>&1 || true"
}

main() {
  stop_local
  stop_remote
  log "Leanstral vLLM is stopped"
}

main "$@"
