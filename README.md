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
- Max batched tokens: `16384`
- EAGLE speculative decoding: disabled by default

The vLLM launch options follow the Hugging Face model card recommendations where
compatible with this hardware:

- `--tool-call-parser mistral`
- `--enable-auto-tool-choice`
- `--reasoning-parser mistral`
- Optional `--speculative-config` with EAGLE draft decoding
- Ray distributed serving

`FLASH_ATTN_MLA` is not enabled by default because it was not valid on the tested
DGX Spark GB10 devices. You can still override the attention backend with
`ATTENTION_BACKEND=...` if your hardware supports it.

## Files

- `start.sh` - starts the Ray cluster, launches vLLM, tails startup logs, waits
  for readiness, verifies chat completion, then returns the terminal.
- `stop.sh` - stops the local head container and the remote worker container.
- `tok-s-benchmark.html` - browser-based tokens-per-second benchmark for the
  OpenAI-compatible endpoint.
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

Cache paths used by the original setup:

- Head: `/home/zurih/.cache/huggingface`
- Worker: set `WORKER_HF_HOME` to the Hugging Face cache path on the worker

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
- `WORKER_HF_HOME=<worker-huggingface-cache>` - Hugging Face cache path as seen
  from the worker. Set this to wherever the model is cached on the second
  machine.
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

## Benchmark

Open `tok-s-benchmark.html` in a browser to benchmark prompt and generation
throughput against the vLLM endpoint.

Suggested settings:

- Base URL: `http://10.0.0.1:8888/v1`
- Model: `mistralai/Leanstral-1.5-119B-A6B`
- API key: `dummy`

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

Thinking is intentionally off in the suggested client configs below. This model
can over-think and spend far too many tokens when reasoning is enabled. Use
`reasoning_effort: "none"` by default, and enable higher reasoning only for
Lean/proof-engineering tasks that actually need it.

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
    "reasoning_effort": "none"
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
      "reasoning": false,
      "input": [
        "text",
        "image"
      ],
      "contextWindow": 262144,
      "maxTokens": 32768,
      "params": {
        "reasoning_effort": "none"
      }
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
| `MAX_NUM_BATCHED_TOKENS`     | `16384`                                  |
| `MM_PROCESSOR_CACHE_TYPE`    | `lru`                                   |
| `ENABLE_EAGLE`               | `0`                                     |
| `ENABLE_TOOL_CALLS`          | `1`                                     |
| `VLLM_ENGINE_ITERATION_TIMEOUT_S` | `600`                              |
| `EAGLE_DRAFT_MODEL`          | `mistralai/Mistral-Small-4-119B-2603-eagle` |
| `EAGLE_NUM_SPECULATIVE_TOKENS` | `3`                                   |
| `EAGLE_MAX_MODEL_LEN`        | `65536`                                 |
| `TENSOR_PARALLEL_SIZE`       | `2`                                     |
| `GPU_MEMORY_UTILIZATION`     | `0.85`                                  |
| `ENFORCE_EAGER`              | `1`                                     |
| `CONTAINER_PREFIX`           | `leanstral-vllm`                        |
| `HF_HOME`                    | `/home/zurih/.cache/huggingface`        |
| `WORKER_HF_HOME`             | worker-specific Hugging Face cache path |
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
MAX_MODEL_LEN=200000 MAX_NUM_SEQS=8 MAX_NUM_BATCHED_TOKENS=16384 PORT=8888 ./start.sh
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
- EAGLE speculative decoding is disabled by default. It can be enabled with
  `ENABLE_EAGLE=1 ./start.sh` using
  `mistralai/Mistral-Small-4-119B-2603-eagle`, matching the Mistral Small 4 vLLM
  recipe. No Leanstral-specific EAGLE draft head is documented at the time this
  README was written. In local testing, EAGLE is not stable for this Leanstral
  setup: it was active during an `execute_model` timeout in `shm_broadcast` and
  caused chat crashes. Keep it off unless you are explicitly testing speculative
  decoding.
- `MM_PROCESSOR_CACHE_TYPE=lru` is set explicitly because the shared-memory
  multimodal processor cache path emitted `shared_worker_lock` warnings in this
  multi-node Ray setup.
- Tool auto-choice is enabled by default. If you need to isolate chat stability
  without tool parsing, start with `ENABLE_TOOL_CALLS=0 ./start.sh`.
- `VLLM_ENGINE_ITERATION_TIMEOUT_S=600` extends vLLM's default engine iteration
  timeout so long first-run JIT or worker synchronization stalls are less likely
  to kill the engine immediately.
