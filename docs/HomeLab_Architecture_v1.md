# Mac mini LLM Home Lab — Architecture

**Target:** Apple Silicon Mac mini, 16–24 GB · kind on podman · NGINX Gateway Fabric ingress · swappable AI gateways · llm-d scheduling plane

---

## 1. The constraint that shapes everything

Docker and podman on Apple Silicon both run containers inside a Linux VM. **Neither passes Metal through to that VM.** There is no `nvidia.com/gpu` equivalent, no device plugin, no accelerator resource to schedule against. Any container-based inference on this machine is CPU inference.

Three consequences follow, and the whole design is a response to them.

**vLLM in-cluster will be slow.** Not "needs tuning" slow — a 0.5B model on 3 CPU cores produces single-digit tokens/sec. That is acceptable for a lab whose subject is orchestration, and unacceptable as your actual inference path.

**llm-d's own CPU backend is unreachable.** Upstream requires 4th-gen Intel Xeon or later for AMX instructions, 64 cores and 64 GB RAM *per replica*. AMX is an x86 extension; it does not exist on ARM. No amount of configuration gets you there. The full well-lit path is out.

**The interesting part of llm-d survives anyway.** Prefill/decode disaggregation is what needs the GPUs. The *scheduling* layer — InferencePool plus the Endpoint Picker, choosing endpoints on live KV-cache utilisation, queue depth and prefix locality — is a small Go service that runs happily on arm64 CPU. That is the part worth learning, and it is the part that transfers unchanged to a real GPU cluster.

So the lab's honest position: **the control plane is real, the accelerator is not.**

---

## 2. Topology

```
  macOS host
  ┌──────────────────────────────────────────────────────────────┐
  │  Ollama / LM Studio / mlx_lm   ← Metal, real tokens/sec       │
  │  :11434                                                       │
  └───────────────────────┬──────────────────────────────────────┘
                          │ gvproxy  (host.containers.internal)
  ┌───────────────────────┼──────────────────────────────────────┐
  │ podman machine (VM)   │                                       │
  │  ┌────────────────────┼───────────────────────────────────┐  │
  │  │ kind node          │                                    │  │
  │  │                    ▼                                    │  │
  │  │  ┌─── llm-serving ────────────────────────────────┐    │  │
  │  │  │  host-bridge (nginx) ──→ host Metal engine     │    │  │
  │  │  │  vllm-cpu × N        ──→ CPU inference, real   │    │  │
  │  │  │  mock-backend × 2    ──→ zero-latency fake     │    │  │
  │  │  │  InferencePool + EPP ──→ llm-d scheduling      │    │  │
  │  │  └────────────────────────▲───────────────────────┘    │  │
  │  │                           │                             │  │
  │  │  ┌─── llm-gateway ────────┴───────────────────────┐    │  │
  │  │  │  Service/ai-gateway  ← the swap point          │    │  │
  │  │  │    = Envoy AI GW | LiteLLM | Bifrost | (none)  │    │  │
  │  │  └────────────────────────▲───────────────────────┘    │  │
  │  │                           │                             │  │
  │  │  ┌─── nginx-gateway ──────┴───────────────────────┐    │  │
  │  │  │  NGINX Gateway Fabric   Gateway/llm-ingress    │    │  │
  │  │  └────────────────────────▲───────────────────────┘    │  │
  │  └───────────────────────────┼─────────────────────────────┘  │
  └──────────────────────────────┼────────────────────────────────┘
                       NodePort 30080 → localhost:8080
```

Four tiers, each independently swappable. Requests enter at `localhost:8080/v1` in OpenAI format and stay OpenAI-shaped the whole way down.

---

## 3. Design decisions

### 3.1 Why NGF and an AI gateway, rather than one of them

They solve different problems and conflating them is the most common mistake in this space.

**NGINX Gateway Fabric** owns north-south HTTP: Gateway API conformance, TLS termination, host and path routing, timeouts, rate limits. It knows nothing about tokens or model names, and it should not.

**The AI gateway** owns the model-aware layer: routing by the `model` field in the request *body*, translating between provider schemas, counting tokens, falling back across providers when one is down.

Keeping them separate means swapping the AI gateway never touches ingress configuration. It also mirrors how this is actually deployed in production, where the edge proxy is owned by a platform team and the AI gateway by whoever owns model serving.

NGF also implements the Gateway API Inference Extension, so `GATEWAY=none` is a legitimate fourth mode: NGF references the InferencePool directly and consults the Endpoint Picker itself, with no AI gateway in the path at all. That is the leanest configuration and the best baseline for latency comparisons.

### 3.2 The swap contract

Every AI gateway overlay must end with one thing:

```
Service/ai-gateway  in  llm-gateway  on  :8080  speaking OpenAI /v1
```

NGF's HTTPRoute targets that name and is never edited. `make gateway GW=litellm` uninstalls whatever was there, installs LiteLLM, and republishes the same Service as an ExternalName alias. The identical smoke test passes against all three.

This is what makes the comparison meaningful. If each gateway had its own route, its own port and its own test, you would be comparing three different systems rather than three implementations of one interface.

### 3.3 What each gateway is actually for

| | Envoy AI Gateway | LiteLLM | Bifrost |
|---|---|---|---|
| Model | Gateway API CRDs | Config file | Config file |
| Keeps EPP in path | **Yes** | No | No |
| Provider breadth | 16ish | Very broad | ~12 |
| Overhead | Low | Moderate | Lowest claimed |
| Best for | K8s-native routing, llm-d integration | Provider abstraction, budgets, fallbacks | Throughput and tail latency |

The row that matters most for this lab is **"keeps EPP in path."** Envoy AI Gateway can consume an InferencePool as a backend, so llm-d's scheduling decisions survive. LiteLLM and Bifrost do their own load balancing, which means putting an InferencePool in front of them is redundant — their router simply overrides it. That is not a defect; it is a different architectural bet. Worth understanding by observing it rather than reading about it.

### 3.4 Why a host bridge instead of ExternalName

The obvious way to reach a Metal engine on the Mac is an ExternalName Service pointing at `host.containers.internal`. It does not work, for a reason worth internalising: **that name lives in the node container's `/etc/hosts`, and pods resolve through cluster DNS, which has never heard of it.**

Rather than inject entries into CoreDNS, the lab runs a ~30 MB nginx pod whose upstream IP is resolved at deploy time (`podman exec` into the node, `getent hosts`, fall back to gvproxy's `192.168.127.254`). The result is an ordinary ClusterIP Service backed by a real pod. Gateways, EndpointSlices, Prometheus scraping and the EPP all treat host-served models exactly like in-cluster ones — no special cases anywhere upstream.

The nginx config disables `proxy_buffering`. Without that, SSE token deltas accumulate in a buffer and streaming silently degrades into one large response at the end. This is the single most common failure in this design and the smoke test checks for it explicitly.

### 3.5 Single node, on purpose

Extra kind workers cost roughly 600 MB each in kubelet and containerd overhead and buy nothing: there is one physical machine and no real failure domain to spread across. The node carries `llm-lab.io/pool` and `llm-lab.io/accelerator` labels so manifests can *express* placement intent — which means adding a real GPU node later is a label change, not a rewrite.

### 3.6 Podman specifics

Podman is not a drop-in for Docker here. Four differences bite:

1. `KIND_EXPERIMENTAL_PROVIDER=podman` must be exported or kind uses Docker.
2. The host is `host.containers.internal`, not `host.docker.internal`, and on macOS it routes through gvproxy at `192.168.127.254`.
3. **Rootless podman and kind are a bad combination.** Kubelet needs cgroup v2 controller delegation that `podman machine` does not configure by default; the symptom is kubelet failing on cpu/memory controllers with an opaque error. Run `podman machine set --rootful`.
4. VM memory is fixed at machine init. There is no settings pane — resizing means `podman machine stop && podman machine set --memory N && podman machine start`.

Preflight checks all four.

---

## 4. Memory budget

Sixteen GB is the binding constraint, and the VM only gets part of it. Assume 10 GB for the podman machine on a 16 GB Mac mini, leaving macOS ~6 GB.

| Component | Resident |
|---|---|
| kind node (kubelet, containerd, etcd, apiserver) | ~1.2 GB |
| NGINX Gateway Fabric | ~120 MB |
| Envoy Gateway + AI Gateway control plane | ~400 MB |
| Envoy data plane | ~150 MB |
| Endpoint Picker | ~80 MB |
| host-bridge nginx | ~30 MB |
| vLLM CPU, 0.5B, per replica | **~3.5 GB** |
| Prometheus (optional) | ~800 MB |

vLLM dominates by an order of magnitude. Hence three profiles:

- **`lite`** (~3 GB) — mock backends only. Instant feedback for gateway and routing work. Use this the majority of the time.
- **`standard`** (~7 GB) — one or two real vLLM replicas plus the host bridge. The everyday configuration.
- **`full`** (~10 GB) — everything including the EPP and Prometheus. Needs a 12 GB+ VM; on a 16 GB Mac mini expect swapping.

On 16 GB, treat `full` as something you run deliberately, not by default.

---

## 5. What is real and what is not

Being precise about this matters more than the lab working.

**Real:** Gateway API and NGF ingress. Envoy AI Gateway CRDs and model-based routing. LiteLLM and Bifrost configuration and behaviour. InferencePool and the Endpoint Picker, scoring on genuine vLLM metrics. vLLM's scheduler, paged attention and OpenAI surface. Every Kubernetes primitive — probes, PVCs, EndpointSlices, RBAC, ext_proc wiring.

**Not real:** Inference speed. GPU scheduling and the device plugin path. Prefill/decode disaggregation and NIXL KV transfer. Multi-node KV-cache locality. Anything about scale.

The gap is deliberate and it is the right gap. Every skill in the first list transfers unchanged to a GPU cluster. Nothing in the second list can be learned on this hardware at any price, so simulating it would teach you something false.

---

## 6. Migration to real accelerators

The design anticipates three moves, in increasing order of effort.

**Add a GPU node to a real cluster.** Change `llm-lab.io/accelerator: none` to the real accelerator label, add `nvidia.com/gpu: 1` limits to the vLLM deployment, swap `VLLM_IMAGE` to an official CUDA image, drop `--device=cpu` and `--enforce-eager`. Everything above the pod — pool, EPP, gateways, routes — is untouched.

**Adopt llm-d's helmfile path.** Once real GPUs exist, replace `manifests/scheduler/llm-d/` with the upstream `llm-d-infra` / `llm-d-modelservice` charts. The InferencePool contract is identical, so the gateway tier does not notice.

**Enable disaggregation.** Two or more GPUs with fast interconnect, then llm-d's prefill/decode split and NIXL become meaningful. This is the only step that cannot be rehearsed here.

**On the Jetson Orin Nano question:** it gives real CUDA in Kubernetes, which is genuinely valuable, but 8 GB of unified memory and ~102 GB/s bandwidth make it *tighter* than the Mac mini, and vLLM there is a from-source build for SM 8.7. It is a better GPU-scheduling lab and a worse inference box. The strongest combination is a k3s cluster with the Mac mini as control plane and the Jetson as a GPU worker — but that means leaving kind behind, which is a separate project.

---

## 7. Known sharp edges

**Do not build vLLM from source on this machine.** There is no official vLLM arm64 CPU image — upstream publishes CPU wheels for x86_64 — which makes compiling look like the obvious answer. It is not. `setup.py bdist_wheel` forks one C++ job per core, each peaking at 2–4 GB, against a VM with ~10 GB total, and dies with `ResourceExhausted: cannot allocate memory`. It is also [known-broken upstream on Apple Silicon](https://github.com/vllm-project/vllm/issues/21714).

`make build-vllm` therefore *pulls* a prebuilt arm64 image, verifies it is genuinely arm64 and that `import vllm` succeeds, then mirrors it into the local registry so cluster rebuilds are instant. Source build is opt-in (`METHOD=source`), forces `MAX_JOBS=1`, and refuses to start on a VM under 16 GB unless you pass `FORCE=1`.

**The lab does not require vLLM at all.** The mock backends emit vLLM-shaped Prometheus metrics, so the Endpoint Picker can score them exactly as it would the real thing — and the host Metal engine supplies genuine inference through the bridge. If no prebuilt image works, `PROFILE=lite` plus `host-bridge` still exercises every layer of the control plane. vLLM in-cluster buys you real engine internals, not a working lab.

Two details that are easy to get wrong. The metric set is **not** a free choice: GIE v1.5.0's extractor reads exactly `vllm:num_requests_waiting`, `vllm:num_requests_running`, `vllm:kv_cache_usage_perc`, `vllm:lora_requests_info` and `vllm:cache_config_info` — note `kv_cache_usage_perc`, which vLLM renamed from `gpu_cache_usage_perc`. Anything missing shows up as a per-scrape `extract failed` in the EPP log and scoring on partial data.

And the mocks deliberately sit **outside** `primary-pool` (`llm-lab.io/inference-pool: mock`). The EPP scores on load, not on which models an endpoint actually serves, so an always-idle mock beats a busy vLLM every time. Put them in the same pool and a request for the real model returns `[mock reply from mock-fast]` and streaming stops working — which looks like a gateway routing bug but is the scheduler behaving correctly on a badly-formed pool.

**Image entrypoints vary.** The official image ENTRYPOINTs to `vllm serve`; community arm64 builds differ or set none. The deployment therefore sets an explicit `command: ["python3","-m","vllm.entrypoints.openai.api_server"]`, which is portable across any image that has vllm installed.

**EPP image architecture — this is the reverse of what you would guess.** The upstream GIE endpoint picker, `registry.k8s.io/gateway-api-inference-extension/epp`, is **amd64-only**: every tag from v0.5.1 through v1.2.0 is a bare `linux/amd64` manifest with no manifest list at all. It pulls without complaint on arm64 and then dies inside the Go runtime under emulation with `runtime: lfstack.push invalid packing` — a pointer-packing assertion that looks nothing like an architecture problem and sends you debugging the scheduler.

`ghcr.io/llm-d/llm-d-inference-scheduler` is the one that publishes a genuine `linux/arm64` manifest, so it is the default here. Its `cmd/epp/main.go` is a thin wrapper around GIE's own `runner.NewRunner()`, so it takes the identical flags and simply registers llm-d's extra scoring plugins on top.

The pairing matters: llm-d v0.8.0 vendors GIE v1.5.0, so `GIE_VERSION` is pinned to v1.5.0 to keep CRDs and binary in step. GIE v1.5.0 spreads its four CRDs across two API groups — `InferencePool` is stable at `inference.networking.k8s.io/v1`, while `InferenceObjective`, `InferencePoolImport` and `InferenceModelRewrite` are alpha under `inference.networking.x-k8s.io` — and the EPP's ClusterRole must grant both. `make verify-images` asserts the arm64 manifest before any of this can bite.

**Startup probes, not liveness, for vLLM.** CPU model loading takes minutes. A liveness probe with default timings kills the pod mid-load, forever. The manifest allows 15 minutes via `startupProbe` before liveness engages.

**Timeouts, everywhere — but not all through the same field.** NGF, the AI gateway and the host bridge each default to timeouts far below what CPU generation needs. All three are set to 600s. If responses die at exactly 30 or 60 seconds, one of them was missed.

The trap is that the obvious knob does not work at the ingress tier. **NGF forbids HTTPRoute rule `timeouts` outright** — unconditionally, not behind a feature flag — and it does not reject the resource for it. The route still reports `Accepted: True`, with the refusal buried in the condition message as `UnsupportedField ... spec.rules[0].timeouts: Forbidden`. So the manifest reads as though 600s is configured while nginx quietly applies its 60s default. NGF's real mechanism is a `ProxySettingsPolicy` targeting the Gateway (`manifests/ingress/ngf/gateway.yaml`), which carries `timeout.{read,send,connect}` and applies to every route through that Gateway.

That same policy is also where ingress-tier response buffering is disabled. Section 3.4 covers `proxy_buffering` on the host bridge, but NGF buffers as well, and the symptom is identical and equally quiet: the request succeeds, tokens simply arrive in one lump at the end instead of streaming.

Envoy AI Gateway has its own version of this: `AIGatewayRoute` rules default to `request: 60s` (its own override of Envoy Gateway's 15s) when `timeouts` is unset, so each rule sets 600s explicitly.

**The host engine must bind `0.0.0.0`.** `OLLAMA_HOST=0.0.0.0 ollama serve`. Bound to `127.0.0.1` it is invisible to the cluster, and the failure looks like a bridge bug rather than a config one.
