# Mac mini LLM Home Lab

Kubernetes-native LLM serving lab for an Apple Silicon Mac mini: **kind on podman**, **NGINX Gateway Fabric** ingress, **swappable AI gateways** (Envoy AI Gateway / LiteLLM / Bifrost), and the **llm-d scheduling plane** over real vLLM CPU backends plus a Metal-accelerated host engine.

```bash
make use-podman   # or: make use-docker   -- see Setup below
make init && make preflight
make bootstrap PROFILE=lite      # ~3 min, validates the whole path
make bootstrap PROFILE=standard  # real vLLM (build the image first)
```

Then:

```bash
curl localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-llm-lab-local' \
  -d '{"model":"qwen-small","messages":[{"role":"user","content":"hello"}]}'
```

## Layout

```
Makefile                     entry point -- make help
.env.example                 all tunables, pinned versions
cluster/kind-config.yaml     single node, NodePort mappings, registry patch
images/vllm-cpu/build.sh     builds vLLM for linux/arm64 (slow, once)
manifests/
  ingress/ngf/               NGINX Gateway Fabric: Gateway + the one HTTPRoute
  backends/host-bridge/      nginx proxy to the Metal engine on macOS
  backends/vllm-cpu/         real vLLM, CPU, small model
  backends/mock/             zero-latency fake, for fast iteration
  scheduler/llm-d/           InferencePool + Endpoint Picker
  gateways/{envoy-ai-gateway,litellm,bifrost}/
scripts/                     preflight, up, backends, gateway, smoke, bench
docs/
  HomeLab_Architecture_v1.md design, tradeoffs, what is real and what is not
  HomeLab_Runbook_v1.md      setup, exercises, troubleshooting
```

## Setup

Runs on **podman or docker** — pick one and follow only that section of the
runbook. They are deliberately kept separate because the setup steps differ and
mixing them is the main way this goes wrong.

- **[Setup A — Podman](docs/HomeLab_Runbook_v1.md#setup-a--podman)**
- **[Setup B — Docker](docs/HomeLab_Runbook_v1.md#setup-b--docker)**

> **Switching between them later?** Read
> [Switching runtimes](docs/HomeLab_Runbook_v1.md#switching-runtimes-read-before-you-do-it)
> first. `make down` **before** you switch — kind clusters are not portable, and
> switching with one running orphans it silently: still holding disk and port
> 8080, but invisible to every command here. `make orphans` finds strays.

```bash
make down       # delete the cluster; keeps registry + vLLM image
make nuke       # delete cluster, registry and cached charts
make orphans    # report resources under EITHER runtime
```

## Observability

```bash
make observability     # kube-prometheus-stack + vLLM dashboard (~700 Mi)
```

Grafana at <http://localhost:9090> (`admin` / `llm-lab`), Prometheus via
`make prom`. Opt-in, never part of `make bootstrap`.

## Read this before running anything

Apple Silicon passes **no GPU into containers**. In-cluster inference is CPU-only and slow, and llm-d's own CPU backend (Intel AMX, 64 cores, 64 GB/replica) is unreachable on ARM at any configuration.

What this lab therefore does: runs the **control plane for real** — Gateway API, model-aware routing, InferencePool and Endpoint Picker scoring on genuine vLLM metrics — while treating the accelerator as the simulated part. Real speed comes from a Metal engine on the host, bridged into the cluster so it looks like any other backend.

Section 5 of the architecture doc lists exactly what is real and what is not. Read it first; the gap is the most useful thing here.
