# Runbook

## Prerequisites

```bash
brew install podman kind kubectl helm jq
```

Podman machine — memory is fixed at init, so size it now:

```bash
podman machine init --cpus 6 --memory 10240 --disk-size 80
podman machine set --rootful          # kind + rootless podman is unreliable
podman machine start
```

Host inference engine (this is where real speed comes from):

```bash
brew install ollama
OLLAMA_HOST=0.0.0.0 ollama serve      # 0.0.0.0, not 127.0.0.1
ollama pull llama3.2:3b
```

---

## First run

```bash
make init            # create .env, then edit it
make preflight       # fails fast on memory, rootless podman, missing host engine
make build-vllm      # pulls a prebuilt arm64 image, ~2 min. skip for PROFILE=lite
make bootstrap       # cluster + CRDs + NGF + backends + gateway + smoke
```

Start with `PROFILE=lite` to validate the whole path in about three minutes before committing to a vLLM build.

---

## Daily use

```bash
make status                    # what is running, what it costs
make smoke                     # end to end
make gateway GW=litellm        # swap the AI gateway in place
make gateway GW=bifrost
make gateway GW=envoy
make gateway GW=none           # NGF straight to the InferencePool
make backends PROFILE=full     # add EPP + mock alongside vLLM
make logs-vllm                 # watch the slow CPU load
make logs-epp                  # watch routing decisions
make bench N=50                # gateway overhead, meaningful only on lite
make recreate                  # delete and rebuild the cluster from scratch
make down                      # delete cluster, keep the built image
make nuke                      # also delete the registry
```

---

## Web UIs

| Gateway | UI | How |
|---|---|---|
| LiteLLM | keys, spend, logs, model list | `make ui` then <http://localhost:8090/ui> — master key `sk-llm-lab-local` |
| Bifrost | config, providers, monitoring | `make ui` then <http://localhost:8090/> |
| Envoy AI Gateway | none | configured through CRDs; `make ui` prints the inspection commands instead |

`make ui` port-forwards the active gateway rather than routing through the
ingress, so it works mid-swap and keeps the UI off the inference port.

Through the ingress on <http://localhost:8080> the same UIs are reachable at the
same paths, since the HTTPRoute now has a catch-all rule alongside `/v1`. The
`/v1` rule keeps its 600s timeout for slow CPU generation; everything else gets
60s, which is what you want for a dashboard that has hung.

For Envoy, inspect config instead of looking for a dashboard:

```bash
kubectl get aigatewayroute,aiservicebackend -n llm-gateway -o yaml
kubectl get gateway,httproute -A
```

## "unsupported path: /v1" in the browser

Not an error. `/v1` is a path prefix; the endpoints below it are `/v1/models`,
`/v1/chat/completions`, `/v1/completions`. The gateway is telling you nothing is
routed at exactly `/v1`, which is correct.

Browsable (GET): <http://localhost:8080/v1/models>

Everything else under `/v1` is POST and needs `curl` or `make smoke`.

## Exercises worth doing

These are the reason the lab exists; running it is not the point.

**1. Prove the swap contract holds.** Run `make smoke` under all four gateway modes. Identical assertions, four very different implementations. Then diff what `/v1/models` returns — the differences in how each gateway advertises models are informative.

**2. Watch the Endpoint Picker choose.** `PROFILE=full`, then `make logs-epp` in one pane while you fire concurrent requests in another. Scale vLLM to 3 replicas and send requests sharing a long prefix; the prefix-cache-aware scorer should converge on one endpoint. That convergence is llm-d's core idea, visible.

**3. Measure the gateway tax.** `PROFILE=lite`, `make bench N=100`, once per gateway. With a zero-latency backend you are measuring only the proxies. Compare against `GW=none`.

**4. Break streaming on purpose.** Set `proxy_buffering on` in the host bridge template, redeploy, run the smoke test. Watch the streaming check fail while everything else passes — the exact failure mode that wastes an afternoon in production.

**5. Fail over across tiers.** With LiteLLM active, stop Ollama on the Mac. Requests to the `auto` alias should fall back. Then stop vLLM instead and observe the difference.

**6. Compare CPU and Metal honestly.** Same prompt through `vllm-cpu` and through `host-bridge`, timed. The ratio is the number to keep in mind whenever you read a benchmark that does not name its hardware.

---

## Troubleshooting

**`kubelet fails on cpu/memory cgroup controllers`**
Rootless podman. `podman machine stop && podman machine set --rootful && podman machine start`.

**`403: denied` pulling a Helm chart from ghcr.io (or docker.io)**

Run `make doctor-registry` first — it separates the causes, which all look identical in helm's output.

The chart is public and the network is almost certainly fine (doctor step 2 proves this with plain curl). The usual cause is **Helm 4 resolving credentials through docker's credential helpers**: `credsStore` / `credHelpers` in `~/.docker/config.json`, backed by the macOS Keychain. An expired ghcr entry gets attached to the anonymous token request and ghcr answers 403 rather than issuing a public token.

The subtlety that makes this hard to diagnose: `--registry-config` only redirects helm to a different auth *file*. The credential comes from a helper, not a file, so a file-level bypass does nothing — and the offending credential never shows up in anything you can `grep`.

`helm_oci()` in `scripts/lib.sh` therefore isolates `DOCKER_CONFIG` to an empty directory as well, which removes helpers from the picture entirely. Doctor step 7 tests exactly this.

To clear the underlying credential:

```bash
docker logout ghcr.io     # the one that matters -- clears the Keychain entry
helm registry logout ghcr.io
podman logout ghcr.io
```

If it still fails, stop fighting the registry client and skip it globally:

```bash
CHART_INSTALL_METHOD=source make up          # in .env, applies to every chart
```

Every project here keeps its chart in-tree, so this clones the release tag and installs from the directory — the identical chart, with no registry client in the path. Slower on first run, then cached in `.state/charts/`.

If doctor reports **docker.io OCI working while ghcr.io fails**, credentials are ruled out — the OCI client is fine. The remaining candidate is IPv4/IPv6: Go's dialer prefers IPv6 where a AAAA record exists, curl on macOS often takes IPv4, and a network whose IPv6 egress is blocked or reputation-listed gets 403 from ghcr over v6 and 200 over v4. Doctor step 9 tests this directly and prints the `/etc/hosts` pin if confirmed.

Doctor step 8 is worth reading before you settle for that: if `helm` resolves to a conda environment, that build vendors its own TLS and auth stack and is a known source of registry failures the official binary does not have. `brew install helm && hash -r` may simply fix it.

Note that LiteLLM and Bifrost use classic HTTP chart repos and are unaffected, so `make gateway GW=litellm` works even when the OCI path is broken. Set `HELM_USE_HOST_AUTH=1` if you genuinely need credentials for a private chart.

**`ERROR: failed to create cluster: node(s) already exist for a cluster with the name "llm-lab"`**
A previous `make up` failed after creating the cluster. `make up` is idempotent — every step is `helm upgrade --install` or a server-side apply — so just re-run it; it detects the existing cluster by container label even when `kind get clusters` does not report it, and resumes. For a clean slate use `make recreate`.

**`metadata.annotations: Too long: may not be more than 262144 bytes`**
Client-side `kubectl apply` stores a full copy of the manifest in the `last-applied-configuration` annotation, and several CRDs here exceed the limit. Every CRD install in `up.sh` uses `--server-side --force-conflicts`, which tracks ownership in `managedFields` instead. If you hit this applying something by hand, add those flags.

**`Gateway` stays `Unprogrammed` / no NGF data plane appears**
`kubectl -n llm-gateway describe gateway llm-ingress`. Usual causes: no GatewayClass named `nginx` (check `kubectl get gatewayclass`), or a listener rejected. `scripts/ingress-nodeport.sh` exits cleanly and tells you this rather than creating an endpoint-less Service; re-run `make up` once the Gateway is Programmed.

**`GATEWAY=none` fails with an unsupported backendRef**
InferencePool as an HTTPRoute backendRef is an experimental Gateway API feature. `.env` now ships `GWAPI_CHANNEL=experimental` by default (the experimental channel is a superset, so it costs the other three modes nothing); if you changed it, set it back and re-run `make up`.

**`GATEWAY=none` reports `BackendNotFound: primary-pool` even though the pool exists**
Two *separate* NGF switches are involved and both default to off. `gwAPIExperimentalFeatures` is not enough — Inference Extension support is its own flag. `up.sh` sets both:
`nginxGateway.gwAPIInferenceExtension.enable=true` and `...endpointPicker.disableTLS=true`. The second matters because NGF talks TLS to the EndpointPicker by default, while the EPP here serves plaintext gRPC with no certificate mounted.

**Switching the Gateway API channel fails with "prohibited by default"**
Gateway API ≥1.4 ships a `ValidatingAdmissionPolicy` (`safe-upgrades.gateway.networking.k8s.io`) that blocks installing experimental CRDs over standard ones. `up.sh` detects a channel change, drops the policy and its binding, and lets the CRD bundle reinstate them moments later — upstream's own documented escape hatch. Nothing to do by hand.

**Every request 500s right after swapping gateways**
Check the HTTPRoute status, not the pods:
`kubectl -n llm-gateway get httproute ai-gateway-route -o yaml | grep -A5 conditions`
`ResolvedRefs=False` with "ExternalName service requires DNS resolver configuration" means NGF has no resolver. The swap contract publishes `Service/ai-gateway` as an ExternalName, and NGINX will not resolve one without `nginx.config.dnsResolver` — `up.sh` sets it from the discovered `kube-dns` ClusterIP.

**A version bump in the repo did not take effect**
`.env` wins over `.env.example` by design, so a stale key shadows the new default. `make preflight` now reports both drifted and missing keys. `make versions` compares your pins against upstream latest.

**`ImagePullBackOff` on ghcr.io images after the chart install succeeded**
Installing charts from git source avoids the chart registry, but workloads still pull container images, and NGF's come from ghcr.io. Those pulls happen in containerd inside the kind node — a different client from helm. Pull them host-side with podman (which demonstrably works here) and side-load:

```bash
make preload-images
```

Pods use `imagePullPolicy: IfNotPresent`, so they will use the side-loaded copies.

**`exec format error` in a CrashLoop**
An amd64-only image. `make verify-images`, then override the offender in `.env`.

**`make build-vllm` fails with `ResourceExhausted: cannot allocate memory`**
You are on the source-build path, which should not be the default. Plain `make build-vllm` pulls a prebuilt arm64 image instead. If you deliberately ran `METHOD=source`, either raise the VM to 16 GB for the duration:
```bash
podman machine stop && podman machine set --memory 16384 && podman machine start
```
or skip vLLM — `PROFILE=lite` plus the host bridge exercises the whole control plane without it.

**`make build-vllm` says no prebuilt image worked**
Three options, best first: (1) run `PROFILE=lite` and use the host Metal engine for real inference — nothing in the control plane depends on in-cluster vLLM; (2) pin a known-good tag with `VLLM_UPSTREAM_IMAGE=...`; (3) `METHOD=source make build-vllm` on a 16 GB VM.

**vLLM pod starts then exits immediately with a usage/arg error**
Image entrypoint mismatch. The deployment sets an explicit `command`, so this means the image lacks `vllm.entrypoints.openai.api_server`. Check with:
```bash
podman run --rm --entrypoint "" $VLLM_IMAGE python3 -c "import vllm; print(vllm.__version__)"
```

**vLLM pod killed and restarted, repeatedly, before ever serving**
Either OOM (`kubectl -n llm-serving describe pod` shows `OOMKilled` — lower `VLLM_REPLICAS` or `VLLM_MAX_MODEL_LEN`) or the liveness probe fired during load (raise `startupProbe.failureThreshold`).

**Requests hang, then fail at exactly 60s**
A timeout you missed — but note the ingress one is *not* set where you would expect. NGF **forbids** HTTPRoute rule `timeouts` outright and ignores them while still reporting the route `Accepted`, with `UnsupportedField ... Forbidden` hidden in the condition message. The ingress timeout lives in the `ProxySettingsPolicy` in `manifests/ingress/ngf/gateway.yaml` (`timeout.read` / `timeout.send`). Also check the AI gateway's own request timeout — `AIGatewayRoute` rules silently default to 60s if `timeouts` is unset — and `proxy_read_timeout` in the host bridge.

**Streaming returns everything at once instead of incrementally**
Buffering, in one of two places. `proxy_buffering off` in the bridge, and `buffering.disable: true` in the ingress `ProxySettingsPolicy` — NGF buffers too, and the request still succeeds either way, so the only symptom is that tokens arrive in one lump.

**`make smoke` fails right after `make gateway`, but passes when re-run by hand**
This was a real race and is now fixed: `gateway.sh` polls `/v1/models` until the ingress actually serves before reporting success. Helm's `--wait` only proves the pods are ready, while NGF still has to re-resolve the ExternalName and Envoy still has to receive new xDS. If you see this again, the readiness gate is being skipped or the 180s budget was exceeded.

**`host-bridge` up but 502 on every request**
The host engine is bound to `127.0.0.1`. Restart with `OLLAMA_HOST=0.0.0.0`. Confirm the resolved IP: `kubectl -n llm-serving exec deploy/host-bridge -- cat /etc/nginx/conf.d/default.conf`.

**`localhost:8080` refuses connections**
The NodePort mapping only exists if the cluster was created with `cluster/kind-config.yaml`. `kubectl -n llm-gateway get svc llm-ingress-nodeport` should show `30080`. If the cluster was created another way, recreate it.

**Pods stuck `Pending`: `node(s) didn't match Pod's node affinity/selector`**
The node is missing `llm-lab.io/pool=inference`. Fix immediately without recreating:

```bash
kubectl label node llm-lab-control-plane \
  llm-lab.io/pool=inference llm-lab.io/accelerator=none --overwrite
```

Root cause worth knowing: kind implements its per-node `labels:` field by generating a `--node-labels` kubelet argument. Supplying your own `kubeadmConfigPatch` containing `node-labels` **replaces** that generated value instead of merging, so `labels:` is silently discarded. All labels now live in the single comma-separated `node-labels` list in `cluster/kind-config.yaml`, and `up.sh` re-applies them post-create as a guarantee.

**Pods `Pending` on insufficient memory**
vLLM replicas request 3Gi each. On a 10GB podman machine only one fits, so `VLLM_REPLICAS=1` is the default; raise it only after enlarging the VM. `make backends` warns about this before deploying.

**vLLM gets `OOMKilled` on every redeploy, but ran fine before**
Not the model — the rollout. A RollingUpdate starts the replacement pod before retiring the old one, so two vLLM processes briefly share a node that fits one, and it is the *new* pod that gets killed mid-load. The deployment uses `strategy: Recreate` for exactly this reason; with a single replica there is nothing to roll anyway.

**InferencePool shows no endpoints**
The pod label selector. Backends need `llm-lab.io/inference-pool: primary`; verify with `kubectl -n llm-serving get pods --show-labels`.

**A request for the real model comes back `[mock reply from mock-fast]`**
Something put the mock backends into `primary-pool`. The EPP scores on queue depth and KV-cache usage and knows nothing about which models an endpoint serves, so a permanently idle mock outscores a loaded vLLM every time. Streaming breaks in the same breath, because the mock answers plain JSON and never SSE. The mocks therefore carry `llm-lab.io/inference-pool: mock` on purpose — do not "fix" that back to `primary`.

**vLLM dies with `Engine core initialization failed`**
Look further up the log for the real cause. On the community arm64 image it is usually TorchInductor: that build ships torch *without* its `torch/csrc/inductor` headers, so the sampler's `torch.compile` shells out to g++ and dies on a missing `cpp_prefix.h`. The deployment sets `TORCHDYNAMO_DISABLE=1` to make `torch.compile` a no-op, which costs nothing when you are on CPU and eager anyway.

**vLLM rejects an argument that the docs say exists**
vLLM 0.26 removed `--device` as a platform selector, and `--swap-space` and `--disable-log-requests` with it. Worse, argparse *prefix-matches* `--device=cpu` onto the surviving `--device-ids`, which wants integers — so it fails deep in engine config with `Non-integer device ID 'cpu' is not supported by cpu` rather than "unknown flag". The platform is auto-detected; pass no `--device` at all.

**The EPP crashloops with `runtime: lfstack.push invalid packing`**
Wrong CPU architecture, not a scheduler bug. The upstream GIE endpoint picker is published amd64-only and dies inside the Go runtime under emulation. `EPP_IMAGE` therefore points at `ghcr.io/llm-d/llm-d-inference-scheduler`, which publishes a real arm64 manifest. `make verify-images` catches this before you deploy.

**Everything is slow and the Mac is unresponsive**
The VM is swapping. `make status` and look at the memory column. Drop to `PROFILE=standard` or `lite`, or reduce `VLLM_REPLICAS` to 1.
