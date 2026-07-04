# Leanstral 1.5 119B A6B on Dual DGX Spark

This repository contains small operational scripts for serving
[`mistralai/Leanstral-1.5-119B-A6B`](https://huggingface.co/mistralai/Leanstral-1.5-119B-A6B)
with vLLM on two DGX Spark machines over the CX7 network.

<p>
<a href="https://x.com/MiaAI_lab" target="_blank">
  <img src="https://img.shields.io/badge/Follow%20me%20on%20X-000000?style=for-the-badge&logo=x&logoColor=white" alt="Follow Mia on X" />
</a>
</p>
<p>
<a href='https://ko-fi.com/Z8Z3SPLOD' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>
</p>

The setup uses:

- Head node: `10.0.0.1`
- Worker node: `10.0.0.2`
- vLLM Docker image: `vllm/vllm-openai:v0.24.0`
- Ray distributed executor
- Tensor parallel size: `2`
- OpenAI-compatible API endpoint: `http://10.0.0.1:8888/v1`
- Inputs: text and image
- Model context length: `262144`
- Max concurrent sequences: `7`
- Max batched tokens: `8192`

The vLLM launch options follow the Hugging Face model card recommendations where
compatible with this hardware:

- `--tool-call-parser mistral`
- `--enable-auto-tool-choice`
- `--reasoning-parser mistral`
- Ray distributed serving

`FLASH_ATTN_MLA` is not enabled by default because it was not valid on the tested
DGX Spark GB10 devices. You can still override the attention backend with
`ATTENTION_BACKEND=...` if your hardware supports it.

## Files

- `start.sh` - starts the Ray cluster, launches vLLM, tails startup logs, waits
  for readiness, verifies chat completion, then returns the terminal.
- `stop.sh` - stops the local head container and the remote worker container.
- `PLANS.md` - implementation notes from the initial setup work.

## Requirements

Run these scripts from the head machine.

Both machines need:

- Docker with NVIDIA GPU support
- Access to `vllm/vllm-openai:v0.24.0`
- Passwordless SSH from the head node to `10.0.0.2`
- CX7 interface available as `enp1s0f1np1` unless overridden
- The model available in the configured Hugging Face cache, or enough network and
  disk capacity to download it on first start

Default cache paths used by the scripts:

- Head: `/home/zurih/.cache/huggingface`
- Worker: `/mnt/spark1/models/.cache/huggingface`

The script mounts those paths into the containers as `/root/.cache/huggingface`.

## Important: Before Running

Review these values before running `./start.sh`. The defaults match the original
two-DGX-Spark setup, but they are machine-specific:

- `HEAD_IP=10.0.0.1` - CX7 IP of the machine where you run `start.sh`.
- `WORKER_IP=10.0.0.2` - CX7 IP of the second DGX Spark. Passwordless SSH from
  the head machine must work.
- `CX7_IFACE=enp1s0f1np1` - network interface used for Ray, NCCL, and Gloo.
  Change it if your CX7 interface has a different name.
- `PORT=8888` - OpenAI-compatible API port. Change it if this port is already in
  use.
- `HF_HOME=/home/zurih/.cache/huggingface` - Hugging Face cache on the head
  machine.
- `WORKER_HF_HOME=/mnt/spark1/models/.cache/huggingface` - Hugging Face cache
  path as seen from the worker.
- `HUGGING_FACE_HUB_TOKEN` or `HF_TOKEN` - optional, but recommended if the model
  is not already fully cached or Hugging Face rate limits downloads.

Minimum pre-flight checks:

```bash
ssh 10.0.0.2 'hostname'
docker run --rm --gpus all vllm/vllm-openai:v0.24.0 nvidia-smi
ssh 10.0.0.2 'docker run --rm --gpus all vllm/vllm-openai:v0.24.0 nvidia-smi'
```

## Start

```bash
./start.sh
```

During startup, the script tails the vLLM Docker container logs. When the API is
ready, it sends a small chat completion request. On success it prints:

```text
vLLM is now up with Leanstral-1.5-119B-A6B
```

At that point the terminal is returned and the service remains running in Docker.

## Stop

```bash
./stop.sh
```

This removes the local head/API container and the worker Ray container on
`10.0.0.2`. It is safe to run more than once.

## API Usage

List models:

```bash
curl -sS http://10.0.0.1:8888/v1/models
```

Chat completion:

```bash
curl -sS http://10.0.0.1:8888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "mistralai/Leanstral-1.5-119B-A6B",
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: Leanstral ready"
      }
    ],
    "temperature": 0,
    "max_tokens": 16,
    "reasoning_effort": "none"
  }'
```

Image input:

```bash
curl -sS http://10.0.0.1:8888/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "mistralai/Leanstral-1.5-119B-A6B",
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "text",
            "text": "Describe this image briefly."
          },
          {
            "type": "image_url",
            "image_url": {
              "url": "https://example.com/image.jpg"
            }
          }
        ]
      }
    ],
    "max_tokens": 128
  }'
```

For Lean/proof-engineering tasks, the model card recommends `temperature: 1.0`
and `reasoning_effort: "high"` for complex prompts.

## Suggested Harness Config

Use the service as an OpenAI-compatible chat completions endpoint:

```json
{
  "base_url": "http://10.0.0.1:8888/v1",
  "api_key": "dummy",
  "model": "mistralai/Leanstral-1.5-119B-A6B",
  "context_window": 262144,
  "max_tokens": 32768,
  "supports_vision": true,
  "supports_reasoning_effort": true,
  "default_params": {
    "temperature": 1.0,
    "reasoning_effort": "high"
  }
}
```

For deterministic smoke tests, use `temperature: 0`, a small `max_tokens`, and
`reasoning_effort: "none"`.

## Pi Agent Config

Example provider entry for `~/.pi/agent/models.json`:

```json
"Leanstral vLLM": {
  "baseUrl": "http://10.0.0.1:8888/v1",
  "api": "openai-completions",
  "apiKey": "dummy",
  "compat": {
    "supportsDeveloperRole": false,
    "supportsReasoningEffort": true,
    "maxTokensField": "max_tokens"
  },
  "models": [
    {
      "id": "mistralai/Leanstral-1.5-119B-A6B",
      "name": "Leanstral 1.5 119B A6B vLLM",
      "reasoning": true,
      "input": [
        "text",
        "image"
      ],
      "contextWindow": 262144,
      "maxTokens": 32768
    }
  ]
}
```

## Configuration

All important settings can be overridden with environment variables:

| Variable                     | Default                                 |
| ---------------------------- | --------------------------------------- |
| `MODEL_ID`                   | `mistralai/Leanstral-1.5-119B-A6B`      |
| `VLLM_IMAGE`                 | `vllm/vllm-openai:v0.24.0`              |
| `HEAD_IP`                    | `10.0.0.1`                              |
| `WORKER_IP`                  | `10.0.0.2`                              |
| `PORT`                       | `8888`                                  |
| `RAY_PORT`                   | `6379`                                  |
| `MAX_MODEL_LEN`              | `262144`                                |
| `MAX_NUM_SEQS`               | `7`                                     |
| `MAX_NUM_BATCHED_TOKENS`     | `8192`                                  |
| `TENSOR_PARALLEL_SIZE`       | `2`                                     |
| `GPU_MEMORY_UTILIZATION`     | `0.85`                                  |
| `ENFORCE_EAGER`              | `1`                                     |
| `CONTAINER_PREFIX`           | `leanstral-vllm`                        |
| `HF_HOME`                    | `/home/zurih/.cache/huggingface`        |
| `WORKER_HF_HOME`             | `/mnt/spark1/models/.cache/huggingface` |
| `CX7_IFACE`                  | `enp1s0f1np1`                           |
| `ATTENTION_BACKEND`          | empty                                   |
| `RAY_OBJECT_STORE_MEMORY`    | `4294967296`                            |
| `RAY_MEMORY_USAGE_THRESHOLD` | `0.99`                                  |
| `HEAD_RAY_TMPDIR`            | `/mnt/ray/leanstral-vllm`               |
| `WORKER_RAY_TMPDIR`          | `/tmp/ray`                              |
| `HEAD_RAY_SPILL_DIR`         | `/mnt/ray/leanstral-vllm-spill`         |
| `WORKER_RAY_SPILL_DIR`       | `/mnt/spark1/ray/leanstral-vllm-spill`  |

Example override:

```bash
MAX_MODEL_LEN=200000 MAX_NUM_SEQS=8 MAX_NUM_BATCHED_TOKENS=8192 PORT=8888 ./start.sh
```

## Docker Containers

Default container names:

- Head/API: `leanstral-vllm-head`
- Worker: `leanstral-vllm-ray-worker`

Inspect logs:

```bash
docker logs -f leanstral-vllm-head
ssh 10.0.0.2 "docker logs -f leanstral-vllm-ray-worker"
```

Check status:

```bash
docker ps --filter name=leanstral-vllm
ssh 10.0.0.2 "docker ps --filter name=leanstral-vllm"
```

## Notes

- First startup can take a long time if model shards need to be downloaded.
- The scripts disable Hugging Face Xet in the containers and extend Hugging Face
  download timeouts to reduce startup failures on large shards.
- The scripts install `ray[default]` inside the vLLM container on startup because
  the selected Docker image does not include the Ray CLI by default.
- Port `8888` is used by default to avoid conflict with services commonly using
  port `8000`.
- The model card recommends context length up to `200k` tokens, while the model
  supports `256k`. This setup currently defaults to `256k`; lower it with
  `MAX_MODEL_LEN=200000` if you want to match the model card recommendation more
  conservatively.


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
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
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
  if [[ -n "${ATTENTION_BACKEND}" ]]; then
    attention_arg="--attention-backend '${ATTENTION_BACKEND}'"
  fi
  if [[ "${ENFORCE_EAGER}" == "1" ]]; then
    eager_arg="--enforce-eager"
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
        --tensor-parallel-size '${TENSOR_PARALLEL_SIZE}' \
        --gpu-memory-utilization '${GPU_MEMORY_UTILIZATION}' \
        ${eager_arg} \
        --no-async-scheduling \
        --distributed-executor-backend ray \
        ${attention_arg} \
        --tool-call-parser mistral \
        --enable-auto-tool-choice \
        --reasoning-parser mistral"
}

start_ray_worker() {
  log "Starting Ray worker on ${WORKER_IP}"
  remote "mkdir -p '${WORKER_HF_HOME}'"
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
  mkdir -p "${HF_HOME}"
  mkdir -p "${HF_HOME}/hub/.locks/models--mistralai--Leanstral-1.5-119B-A6B"
  mkdir -p "${HF_HOME}/xet/logs"
  chmod a+rwX "${HF_HOME}" "${HF_HOME}/hub" "${HF_HOME}/xet" "${HF_HOME}/xet/logs" 2>/dev/null || true
  chmod -R a+rwX "${HF_HOME}/hub/.locks" "${HF_HOME}/hub/models--mistralai--Leanstral-1.5-119B-A6B" 2>/dev/null || true
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


The setup uses:

- Head node: `10.0.0.1`
- Worker node: `10.0.0.2`
- vLLM Docker image: `vllm/vllm-openai:v0.24.0`
- Ray distributed executor
- Tensor parallel size: `2`
- OpenAI-compatible API endpoint: `http://10.0.0.1:8001/v1`
- Model context length: `262144`
- Max concurrent sequences: `7`

The vLLM launch options follow the Hugging Face model card recommendations where
compatible with this hardware:

- `--tool-call-parser mistral`
- `--enable-auto-tool-choice`
- `--reasoning-parser mistral`
- Ray distributed serving

`FLASH_ATTN_MLA` is not enabled by default because it was not valid on the tested
DGX Spark GB10 devices. You can still override the attention backend with
`ATTENTION_BACKEND=...` if your hardware supports it.

## Files

- `start.sh` - starts the Ray cluster, launches vLLM, tails startup logs, waits
  for readiness, verifies chat completion, then returns the terminal.
- `stop.sh` - stops the local head container and the remote worker container.
- `PLANS.md` - implementation notes from the initial setup work.

## Requirements

Run these scripts from the head machine.

Both machines need:

- Docker with NVIDIA GPU support
- Access to `vllm/vllm-openai:v0.24.0`
- Passwordless SSH from the head node to `10.0.0.2`
- CX7 interface available as `enp1s0f1np1` unless overridden
- The model available in the configured Hugging Face cache, or enough network and
  disk capacity to download it on first start

Default cache paths:

- Head: `/mnt/models/.cache/huggingface`
- Worker: `/mnt/spark1/models/.cache/huggingface`

The script mounts those paths into the containers as `/root/.cache/huggingface`.

## Important: Before Running

Review these values before running `./start.sh`. The defaults match the original
two-DGX-Spark setup, but they are machine-specific:

- `HEAD_IP=10.0.0.1` - CX7 IP of the machine where you run `start.sh`.
- `WORKER_IP=10.0.0.2` - CX7 IP of the second DGX Spark. Passwordless SSH from
  the head machine must work.
- `CX7_IFACE=enp1s0f1np1` - network interface used for Ray, NCCL, and Gloo.
  Change it if your CX7 interface has a different name.
- `PORT=8001` - OpenAI-compatible API port. Change it if this port is already in
  use.
- `HF_HOME=/mnt/models/.cache/huggingface` - Hugging Face cache on the head
  machine.
- `WORKER_HF_HOME=/mnt/spark1/models/.cache/huggingface` - Hugging Face cache
  path as seen from the worker.
- `HUGGING_FACE_HUB_TOKEN` or `HF_TOKEN` - optional, but recommended if the model
  is not already fully cached or Hugging Face rate limits downloads.

Minimum pre-flight checks:

```bash
ssh 10.0.0.2 'hostname'
docker run --rm --gpus all vllm/vllm-openai:v0.24.0 nvidia-smi
ssh 10.0.0.2 'docker run --rm --gpus all vllm/vllm-openai:v0.24.0 nvidia-smi'
```

## Start

```bash
./start.sh
```

During startup, the script tails the vLLM Docker container logs. When the API is
ready, it sends a small chat completion request. On success it prints:

```text
vLLM is now up with Leanstral-1.5-119B-A6B
```

At that point the terminal is returned and the service remains running in Docker.

## Stop

```bash
./stop.sh
```

This removes the local head/API container and the worker Ray container on
`10.0.0.2`. It is safe to run more than once.

## API Usage

List models:

```bash
curl -sS http://10.0.0.1:8001/v1/models
```

Chat completion:

```bash
curl -sS http://10.0.0.1:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "mistralai/Leanstral-1.5-119B-A6B",
    "messages": [
      {
        "role": "user",
        "content": "Reply with exactly: Leanstral ready"
      }
    ],
    "temperature": 0,
    "max_tokens": 16,
    "reasoning_effort": "none"
  }'
```

For Lean/proof-engineering tasks, the model card recommends `temperature: 1.0`
and `reasoning_effort: "high"` for complex prompts.

## Configuration

All important settings can be overridden with environment variables:

| Variable                     | Default                                 |
| ---------------------------- | --------------------------------------- |
| `MODEL_ID`                   | `mistralai/Leanstral-1.5-119B-A6B`      |
| `VLLM_IMAGE`                 | `vllm/vllm-openai:v0.24.0`              |
| `HEAD_IP`                    | `10.0.0.1`                              |
| `WORKER_IP`                  | `10.0.0.2`                              |
| `PORT`                       | `8001`                                  |
| `RAY_PORT`                   | `6379`                                  |
| `MAX_MODEL_LEN`              | `262144`                                |
| `MAX_NUM_SEQS`               | `7`                                     |
| `TENSOR_PARALLEL_SIZE`       | `2`                                     |
| `GPU_MEMORY_UTILIZATION`     | `0.85`                                  |
| `ENFORCE_EAGER`              | `1`                                     |
| `CONTAINER_PREFIX`           | `leanstral-vllm`                        |
| `HF_HOME`                    | `/mnt/models/.cache/huggingface`        |
| `WORKER_HF_HOME`             | `/mnt/spark1/models/.cache/huggingface` |
| `CX7_IFACE`                  | `enp1s0f1np1`                           |
| `ATTENTION_BACKEND`          | empty                                   |
| `RAY_OBJECT_STORE_MEMORY`    | `4294967296`                            |
| `RAY_MEMORY_USAGE_THRESHOLD` | `0.99`                                  |
| `HEAD_RAY_TMPDIR`            | `/mnt/ray/leanstral-vllm`               |
| `WORKER_RAY_TMPDIR`          | `/tmp/ray`                              |
| `HEAD_RAY_SPILL_DIR`         | `/mnt/ray/leanstral-vllm-spill`         |
| `WORKER_RAY_SPILL_DIR`       | `/mnt/spark1/ray/leanstral-vllm-spill`  |

Example override:

```bash
MAX_MODEL_LEN=200000 MAX_NUM_SEQS=8 PORT=8001 ./start.sh
```

## Docker Containers

Default container names:

- Head/API: `leanstral-vllm-head`
- Worker: `leanstral-vllm-ray-worker`

Inspect logs:

```bash
docker logs -f leanstral-vllm-head
ssh 10.0.0.2 "docker logs -f leanstral-vllm-ray-worker"
```

Check status:

```bash
docker ps --filter name=leanstral-vllm
ssh 10.0.0.2 "docker ps --filter name=leanstral-vllm"
```

## Notes

- First startup can take a long time if model shards need to be downloaded.
- The scripts disable Hugging Face Xet in the containers and extend Hugging Face
  download timeouts to reduce startup failures on large shards.
- The scripts install `ray[default]` inside the vLLM container on startup because
  the selected Docker image does not include the Ray CLI by default.
- Port `8001` is used by default to avoid conflict with services commonly using
  port `8000`.
- The model card recommends context length up to `200k` tokens, while the model
  supports `256k`. This setup currently defaults to `256k`; lower it with
  `MAX_MODEL_LEN=200000` if you want to match the model card recommendation more
  conservatively.
