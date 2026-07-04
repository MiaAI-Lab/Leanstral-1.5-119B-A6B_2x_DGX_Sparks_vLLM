#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_ID="${MODEL_ID:-mistralai/Leanstral-1.5-119B-A6B}"
IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.24.0}"
HEAD_IP="${HEAD_IP:-10.0.0.1}"
WORKER_IP="${WORKER_IP:-10.0.0.2}"
PORT="${PORT:-8888}"
RAY_PORT="${RAY_PORT:-6379}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-7}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-16384}"
MM_PROCESSOR_CACHE_TYPE="${MM_PROCESSOR_CACHE_TYPE:-lru}"
ENABLE_EAGLE="${ENABLE_EAGLE:-0}"
ENABLE_TOOL_CALLS="${ENABLE_TOOL_CALLS:-1}"
VLLM_ENGINE_ITERATION_TIMEOUT_S="${VLLM_ENGINE_ITERATION_TIMEOUT_S:-600}"
EAGLE_DRAFT_MODEL="${EAGLE_DRAFT_MODEL:-mistralai/Mistral-Small-4-119B-2603-eagle}"
EAGLE_NUM_SPECULATIVE_TOKENS="${EAGLE_NUM_SPECULATIVE_TOKENS:-3}"
EAGLE_MAX_MODEL_LEN="${EAGLE_MAX_MODEL_LEN:-65536}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-2}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.85}"
ENFORCE_EAGER="${ENFORCE_EAGER:-1}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-leanstral-vllm}"
HF_HOME="${HF_HOME:-/home/zurih/.cache/huggingface}"
WORKER_HF_HOME="${WORKER_HF_HOME:-/mnt/spark1/models/.cache/huggingface}"
CX7_IFACE="${CX7_IFACE:-enp1s0f1np1}"
ATTENTION_BACKEND="${ATTENTION_BACKEND:-}"
RAY_OBJECT_STORE_MEMORY="${RAY_OBJECT_STORE_MEMORY:-4294967296}"
RAY_MEMORY_USAGE_THRESHOLD="${RAY_MEMORY_USAGE_THRESHOLD:-0.99}"
HEAD_RAY_TMPDIR="${HEAD_RAY_TMPDIR:-/mnt/ray/leanstral-vllm}"
WORKER_RAY_TMPDIR="${WORKER_RAY_TMPDIR:-/tmp/ray}"
HEAD_RAY_SPILL_DIR="${HEAD_RAY_SPILL_DIR:-/mnt/ray/leanstral-vllm-spill}"
WORKER_RAY_SPILL_DIR="${WORKER_RAY_SPILL_DIR:-/mnt/spark1/ray/leanstral-vllm-spill}"
DOCKER_COMMON_ARGS=(
  --gpus all
  --ipc=host
  --network host
  --shm-size 16g
  -v "${HF_HOME}:/root/.cache/huggingface"
  -v "${HEAD_RAY_TMPDIR}:${HEAD_RAY_TMPDIR}"
  -v "${HEAD_RAY_SPILL_DIR}:${HEAD_RAY_SPILL_DIR}"
  -e "HF_HOME=/root/.cache/huggingface"
  -e "HF_HUB_DISABLE_XET=1"
  -e "HF_HUB_DOWNLOAD_TIMEOUT=600"
  -e "HF_HUB_ETAG_TIMEOUT=600"
  -e "HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}"
  -e "HF_TOKEN=${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  -e "VLLM_HOST_IP=${HEAD_IP}"
  -e "GLOO_SOCKET_IFNAME=${CX7_IFACE}"
  -e "NCCL_SOCKET_IFNAME=${CX7_IFACE}"
  -e "RAY_memory_usage_threshold=${RAY_MEMORY_USAGE_THRESHOLD}"
  -e "VLLM_ENGINE_ITERATION_TIMEOUT_S=${VLLM_ENGINE_ITERATION_TIMEOUT_S}"
  -e "RAY_TMPDIR=${HEAD_RAY_TMPDIR}"
  -e "RAY_ADDRESS=${HEAD_IP}:${RAY_PORT}"
  -e "RAY_object_spilling_config={\"type\":\"filesystem\",\"params\":{\"directory_path\":\"${HEAD_RAY_SPILL_DIR}\"}}"
)

HEAD_RAY_CONTAINER="${CONTAINER_PREFIX}-head"
WORKER_RAY_CONTAINER="${CONTAINER_PREFIX}-ray-worker"
OLD_HEAD_RAY_CONTAINER="${CONTAINER_PREFIX}-ray-head"
OLD_API_CONTAINER="${CONTAINER_PREFIX}-api"
API_CONTAINER="${HEAD_RAY_CONTAINER}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${WORKER_IP}" "$@"
}

hf_cache_dir() {
  printf 'models--%s\n' "${1//\//--}"
}

prepare_hf_cache() {
  local cache_home="$1"
  local main_cache_dir
  local eagle_cache_dir
  main_cache_dir="$(hf_cache_dir "${MODEL_ID}")"
  eagle_cache_dir="$(hf_cache_dir "${EAGLE_DRAFT_MODEL}")"

  mkdir -p "${cache_home}/hub/.locks/${main_cache_dir}"
  mkdir -p "${cache_home}/xet/logs"
  chmod a+rwX "${cache_home}" "${cache_home}/hub" "${cache_home}/xet" "${cache_home}/xet/logs" 2>/dev/null || true
  chmod -R a+rwX "${cache_home}/hub/.locks" "${cache_home}/hub/${main_cache_dir}" 2>/dev/null || true

  if [[ "${ENABLE_EAGLE}" == "1" ]]; then
    mkdir -p "${cache_home}/hub/.locks/${eagle_cache_dir}"
    chmod -R a+rwX "${cache_home}/hub/.locks/${eagle_cache_dir}" "${cache_home}/hub/${eagle_cache_dir}" 2>/dev/null || true
  fi
}

cleanup_local() {
  docker rm -f "${API_CONTAINER}" "${OLD_HEAD_RAY_CONTAINER}" "${OLD_API_CONTAINER}" >/dev/null 2>&1 || true
}

cleanup_remote() {
  remote "docker rm -f '${WORKER_RAY_CONTAINER}' >/dev/null 2>&1 || true"
}

cleanup_all() {
  cleanup_local
  cleanup_remote
}

start_ray_head() {
  log "Starting Ray head on ${HEAD_IP}"
  local attention_arg=""
  local eager_arg=""
  local speculative_arg=""
  local tool_args=""
  if [[ -n "${ATTENTION_BACKEND}" ]]; then
    attention_arg="--attention-backend '${ATTENTION_BACKEND}'"
  fi
  if [[ "${ENFORCE_EAGER}" == "1" ]]; then
    eager_arg="--enforce-eager"
  fi
  if [[ "${ENABLE_EAGLE}" == "1" ]]; then
    speculative_arg="--speculative-config '{\"model\":\"${EAGLE_DRAFT_MODEL}\",\"num_speculative_tokens\":${EAGLE_NUM_SPECULATIVE_TOKENS},\"method\":\"eagle\",\"max_model_len\":\"${EAGLE_MAX_MODEL_LEN}\"}'"
  fi
  if [[ "${ENABLE_TOOL_CALLS}" == "1" ]]; then
    tool_args="--tool-call-parser mistral --enable-auto-tool-choice"
  fi
  mkdir -p "${HEAD_RAY_TMPDIR}"
  mkdir -p "${HEAD_RAY_SPILL_DIR}"
  docker run -d --name "${HEAD_RAY_CONTAINER}" \
    "${DOCKER_COMMON_ARGS[@]}" \
    --entrypoint bash \
    "${IMAGE}" \
    -lc "python3 -m pip install -q 'ray[default]' && \
      ray start --head --node-ip-address='${HEAD_IP}' --port='${RAY_PORT}' --dashboard-host=0.0.0.0 --object-store-memory='${RAY_OBJECT_STORE_MEMORY}' --temp-dir='${HEAD_RAY_TMPDIR}' && \
      until ray status 2>/dev/null | awk '/^Active:/{active=1; next} /^Pending:/{active=0} active && /^[[:space:]]*[0-9]+ node_/{sum+=\$1} END{exit !(sum >= 2)}'; do sleep 3; done && \
      vllm serve '${MODEL_ID}' \
        --host 0.0.0.0 \
        --port '${PORT}' \
        --max-model-len '${MAX_MODEL_LEN}' \
        --max-num-seqs '${MAX_NUM_SEQS}' \
        --max-num-batched-tokens '${MAX_NUM_BATCHED_TOKENS}' \
        --mm-processor-cache-type '${MM_PROCESSOR_CACHE_TYPE}' \
        --tensor-parallel-size '${TENSOR_PARALLEL_SIZE}' \
        --gpu-memory-utilization '${GPU_MEMORY_UTILIZATION}' \
        ${eager_arg} \
        --no-async-scheduling \
        --distributed-executor-backend ray \
        ${attention_arg} \
        ${speculative_arg} \
        ${tool_args} \
        --reasoning-parser mistral"
}

start_ray_worker() {
  log "Starting Ray worker on ${WORKER_IP}"
  remote "mkdir -p '${WORKER_HF_HOME}'"
  remote "mkdir -p '${WORKER_HF_HOME}/hub/.locks/$(hf_cache_dir "${MODEL_ID}")' '${WORKER_HF_HOME}/xet/logs'"
  remote "chmod a+rwX '${WORKER_HF_HOME}' '${WORKER_HF_HOME}/hub' '${WORKER_HF_HOME}/xet' '${WORKER_HF_HOME}/xet/logs' 2>/dev/null || true"
  remote "chmod -R a+rwX '${WORKER_HF_HOME}/hub/.locks' '${WORKER_HF_HOME}/hub/$(hf_cache_dir "${MODEL_ID}")' 2>/dev/null || true"
  if [[ "${ENABLE_EAGLE}" == "1" ]]; then
    remote "mkdir -p '${WORKER_HF_HOME}/hub/.locks/$(hf_cache_dir "${EAGLE_DRAFT_MODEL}")'"
    remote "chmod -R a+rwX '${WORKER_HF_HOME}/hub/.locks/$(hf_cache_dir "${EAGLE_DRAFT_MODEL}")' '${WORKER_HF_HOME}/hub/$(hf_cache_dir "${EAGLE_DRAFT_MODEL}")' 2>/dev/null || true"
  fi
  remote "mkdir -p '${WORKER_RAY_TMPDIR}'"
  remote "mkdir -p '${WORKER_RAY_SPILL_DIR}'"
  remote "docker run -d --name '${WORKER_RAY_CONTAINER}' \
    --gpus all \
    --ipc=host \
    --network host \
    --shm-size 16g \
    -v '${WORKER_HF_HOME}:/root/.cache/huggingface' \
    -v '${WORKER_RAY_TMPDIR}:${WORKER_RAY_TMPDIR}' \
    -v '${WORKER_RAY_SPILL_DIR}:${WORKER_RAY_SPILL_DIR}' \
    -e 'HF_HOME=/root/.cache/huggingface' \
    -e 'HF_HUB_DISABLE_XET=1' \
    -e 'HF_HUB_DOWNLOAD_TIMEOUT=600' \
    -e 'HF_HUB_ETAG_TIMEOUT=600' \
    -e 'HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}' \
    -e 'HF_TOKEN=${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}' \
    -e 'VLLM_HOST_IP=${WORKER_IP}' \
    -e 'GLOO_SOCKET_IFNAME=${CX7_IFACE}' \
    -e 'NCCL_SOCKET_IFNAME=${CX7_IFACE}' \
    -e 'RAY_memory_usage_threshold=${RAY_MEMORY_USAGE_THRESHOLD}' \
    -e 'VLLM_ENGINE_ITERATION_TIMEOUT_S=${VLLM_ENGINE_ITERATION_TIMEOUT_S}' \
    -e 'RAY_TMPDIR=${WORKER_RAY_TMPDIR}' \
    -e 'RAY_object_spilling_config={\"type\":\"filesystem\",\"params\":{\"directory_path\":\"${WORKER_RAY_SPILL_DIR}\"}}' \
    --entrypoint bash \
    '${IMAGE}' \
    -lc \"python3 -m pip install -q 'ray[default]' && ray start --node-ip-address='${WORKER_IP}' --address='${HEAD_IP}:${RAY_PORT}' --object-store-memory='${RAY_OBJECT_STORE_MEMORY}' --temp-dir='${WORKER_RAY_TMPDIR}' --block\""
}

wait_for_ray_nodes() {
  log "Waiting for both Ray nodes"
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${HEAD_RAY_CONTAINER}"; then
      docker logs "${HEAD_RAY_CONTAINER}" --tail 200 || true
      remote "docker logs '${WORKER_RAY_CONTAINER}' --tail 200" || true
      echo "Ray head container exited before both nodes joined." >&2
      return 1
    fi
    if docker exec "${HEAD_RAY_CONTAINER}" bash -lc "ray status 2>/dev/null | awk '/^Active:/{active=1; next} /^Pending:/{active=0} active && /^[[:space:]]*[0-9]+ node_/{sum+=\$1} END{exit !(sum >= 2)}'" ; then
      return 0
    fi
    sleep 3
  done
  docker logs "${HEAD_RAY_CONTAINER}" --tail 200 || true
  remote "docker logs '${WORKER_RAY_CONTAINER}' --tail 200" || true
  echo "Ray cluster did not report 2 nodes before timeout." >&2
  return 1
}

start_vllm_api() {
  log "vLLM API server will run from the Ray head container on ${HEAD_IP}:${PORT}"
}

wait_for_vllm() {
  log "Showing vLLM logs until the API is ready"
  docker logs -f "${API_CONTAINER}" &
  local log_pid=$!
  trap 'kill ${log_pid} >/dev/null 2>&1 || true' RETURN

  local deadline=$((SECONDS + 3600))
  while (( SECONDS < deadline )); do
    if curl -fsS "http://${HEAD_IP}:${PORT}/v1/models" >/dev/null 2>&1; then
      kill "${log_pid}" >/dev/null 2>&1 || true
      wait "${log_pid}" 2>/dev/null || true
      trap - RETURN
      return 0
    fi
    if ! docker ps --format '{{.Names}}' | grep -qx "${API_CONTAINER}"; then
      kill "${log_pid}" >/dev/null 2>&1 || true
      wait "${log_pid}" 2>/dev/null || true
      trap - RETURN
      docker logs "${API_CONTAINER}" --tail 200 || true
      echo "vLLM container exited before becoming ready." >&2
      return 1
    fi
    if docker exec "${API_CONTAINER}" bash -lc "pgrep -f 'vllm serve' >/dev/null || pgrep -f 'APIServer' >/dev/null" >/dev/null 2>&1; then
      :
    else
      kill "${log_pid}" >/dev/null 2>&1 || true
      wait "${log_pid}" 2>/dev/null || true
      trap - RETURN
      docker logs "${API_CONTAINER}" --tail 200 || true
      echo "vLLM process exited before becoming ready." >&2
      return 1
    fi
    sleep 5
  done

  kill "${log_pid}" >/dev/null 2>&1 || true
  wait "${log_pid}" 2>/dev/null || true
  trap - RETURN
  echo "Timed out waiting for vLLM readiness." >&2
  return 1
}

verify_chat() {
  log "Verifying chat completion"
  local response
  response="$(curl -fsS "http://${HEAD_IP}:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{
      \"model\": \"${MODEL_ID}\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Reply with exactly: Leanstral ready\"}],
      \"temperature\": 0,
      \"max_tokens\": 16,
      \"reasoning_effort\": \"none\"
    }")"

  if ! printf '%s' "${response}" | grep -q '"choices"'; then
    printf '%s\n' "${response}" >&2
    echo "Chat verification response did not contain choices." >&2
    return 1
  fi
}

main() {
  prepare_hf_cache "${HF_HOME}"
  log "Using image ${IMAGE}"
  log "Using model ${MODEL_ID}"
  cleanup_all
  start_ray_head
  start_ray_worker
  wait_for_ray_nodes
  start_vllm_api
  wait_for_vllm
  verify_chat
  printf 'vLLM is now up with Leanstral-1.5-119B-A6B\n'
}

main "$@"
