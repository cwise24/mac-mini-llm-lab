# Runbook

kind runs on **either podman or docker** — not both at once on the same machine
without a full teardown in between.

Pick one and follow **only that section**:

- [Setup A — Podman](#setup-a--podman)
- [Switching runtimes](#switching-runtimes-read-before-you-do-it) ← read before changing your mind
- [Setup B — Docker](#setup-b--docker)

`CONTAINER_CLI` in `.env` is the only setting. `KIND_EXPERIMENTAL_PROVIDER` and
`HOST_INTERNAL_NAME` are derived from it in `scripts/lib.sh`. Do not set those by
hand — all three must agree, and setting them separately is how you get
`CONTAINER_CLI=docker` beside a stale `KIND_EXPERIMENTAL_PROVIDER=podman`, which
builds a cluster one tool cannot see.

---

# Setup A — Podman

Complete, self-contained. Ignore the Docker section entirely.

### A1. Install

```bash
brew install podman kind kubectl helm jq
```

### A2. Create the machine

Memory and CPU are **fixed at creation**. There is no settings pane, so size it
correctly now — resizing later means stopping the machine.

```bash
podman machine init --cpus 6 --memory 10240 --disk-size 80
podman machine set --rootful
podman machine start
```

`--rootful` is not optional. kind on rootless podman needs cgroup v2 controller
delegation that `podman machine` does not configure, and the failure is kubelet
dying on cpu/memory controllers with an error that names neither podman nor
rootlessness. `make preflight` checks this.

To resize later:

```bash
podman machine stop
podman machine set --memory 12288 --cpus 6
podman machine start
```

### A3. Host inference engine

This is where real tokens/sec come from — the in-cluster vLLM is CPU-only.

```bash
brew install ollama
OLLAMA_HOST=0.0.0.0 ollama serve      # 0.0.0.0, NOT 127.0.0.1
ollama pull llama3.2:3b
```

Bound to `127.0.0.1` the engine is invisible to the cluster, and the failure
looks like a bridge bug rather than a config one.

### A4. Build

```bash
make use-podman      # sets CONTAINER_CLI=podman
make init            # create .env
make preflight       # memory, rootful check, host engine
make build-vllm      # pulls a prebuilt arm64 image, ~2 min
make bootstrap       # cluster + CRDs + NGF + backends + gateway + smoke
```

Start with `PROFILE=lite` to validate the whole path in ~3 minutes before
committing to a vLLM pull.

### A5. Podman-specific facts

| | |
|---|---|
| kind provider | `KIND_EXPERIMENTAL_PROVIDER=podman` (derived) |
| Host from a pod | `host.containers.internal`, gvproxy at `192.168.127.254` |
| Resource sizing | fixed at `podman machine init` |
| Root mode | must be rootful |

---

# Cleaning up

| Command | Removes | Keeps |
|---|---|---|
| `make down` | the cluster, plus orphaned node containers | registry, vLLM image, `.state/` chart clones |
| `make nuke` | cluster **and** registry **and** `.state/` | nothing |
| `make orphans` | nothing — reports only | — |

`make down` before switching runtimes, before a long break, or any time you want
the RAM back. It deliberately keeps the registry, because the vLLM image is the
expensive thing to rebuild.

`make nuke` when you want the disk back or suspect cached charts are stale.
Expect the next build to re-pull ~550 MB of vLLM plus the chart clones.

Neither touches the model cache inside the cluster's PVC — that dies with the
cluster, so **`make down` does mean re-downloading Qwen** on the next
`make backends`.

---

# Switching runtimes (read before you do it)

> **Run `make down` FIRST. Always.**
>
> ```bash
> make down          # 1. destroy the cluster under the CURRENT runtime
> make orphans       # 2. confirm nothing is left anywhere
> make use-docker    # 3. now switch   (or: make use-podman)
> make bootstrap     # 4. rebuild
> ```

### Why the order matters

kind clusters are **not portable** between podman and docker. Switching while one
exists does not produce an error. The containers keep running under the **old**
runtime, but `kind get clusters` now asks the **new** one and reports nothing.

The result is a cluster that:

- still occupies several GB of disk,
- still binds port 8080, so the next cluster's ingress silently fails,
- is invisible to `make status`, `make down` and every other command here,
  because they all follow `CONTAINER_CLI`.

Nothing warns you, because from the new runtime's point of view it simply is not
there.

### Guard rails

`make use-docker` and `make use-podman` refuse to switch while a cluster is live,
and print what to run. `FORCE=1` overrides, but then cleanup is on you:

```bash
FORCE=1 make use-docker
podman rm -f $(podman ps -aq --filter label=io.x-k8s.kind.cluster=llm-lab)
```

`make orphans` audits **both** runtimes and is the only command here that looks
outside the configured one. Run it after any switch.

### The registry does not follow you either

The local registry is runtime-scoped and holds the vLLM image (~550 MB). The new
runtime starts an empty one, so `make build-vllm` re-pulls. Harmless, just slow —
and worth knowing before you assume something broke.

### Port 8080 already in use

Almost always a stranded cluster from an un-cleaned switch:

```bash
make orphans
```

### `make orphans` reports a docker orphan that isn't one (2026-08-16)

Before removing anything `make orphans` suggests, run `docker context ls` and
check `$DOCKER_HOST`. On at least one machine this repo runs on, `docker`'s
`default` context (or `DOCKER_HOST`) points at **podman's own socket**
(`unix:///.../containers/podman/machine/podman.sock`) rather than Docker
Desktop's. `docker ps` then returns podman's own containers verbatim —
same container ID and all — under the `docker` CLI name. `make orphans`
originally treated any node visible via `docker` while `CONTAINER_CLI=podman`
as an orphan under a genuinely separate runtime, and printed `docker rm -f
$(docker ps -aq --filter label=io.x-k8s.kind.cluster)` as the fix. Running
that command does not clean up a stray cluster — it **deletes the active
podman cluster**, because there was only ever one cluster, visible through
two CLI names. This happened for real during the 2026-08-16 pass: a live,
correctly-running podman cluster got deleted this way, believing it was
docker debris.

`orphans.sh` now compares container **IDs**, not just names, between the
active runtime and the other one, and reports "same daemon under a second
CLI name" instead of "orphan" when they match — the ID comparison is
authoritative because a real second runtime can never produce the same
container ID as the first. If you see the old warning message on an older
checkout, verify with `docker context ls` / `$DOCKER_HOST` before running
the `rm -f` it suggests.

---

# Setup B — Docker

Complete, self-contained. Ignore the Podman section entirely.

### B1. Install

```bash
brew install kind kubectl helm jq
brew install --cask docker
```

Start Docker Desktop and wait for the whale icon to settle.

### B2. Size the VM

Unlike podman there is no machine to create, and resources are changed live:

**Docker Desktop → Settings → Resources**

- CPUs: **6** or more
- Memory: **10 GB** or more
- Disk: 80 GB or more

Apply & Restart. `make preflight` reads these back and fails if they are short.

### B3. Host inference engine

Identical to podman — the engine runs on macOS, not in a container:

```bash
brew install ollama
OLLAMA_HOST=0.0.0.0 ollama serve      # 0.0.0.0, NOT 127.0.0.1
ollama pull llama3.2:3b
```

### B4. Build

```bash
make use-docker      # sets CONTAINER_CLI=docker
make init            # create .env
make preflight       # memory, cpus, host engine
make build-vllm      # pulls a prebuilt arm64 image, ~2 min
make bootstrap       # cluster + CRDs + NGF + backends + gateway + smoke
```

### B5. Docker-specific facts

| | |
|---|---|
| kind provider | unset — kind defaults to docker and rejects any other value |
| Host from a pod | `host.docker.internal` |
| Resource sizing | Docker Desktop → Settings → Resources, live |
| Root mode | n/a |

Note: on Apple Silicon, Docker Desktop passes **no GPU** into the VM, exactly as
podman does not. Neither runtime gives you Metal in-cluster. See
`HomeLab_Architecture_v1.md` §1.

---

## Daily use

```bash
make status                    # what is running, what it costs
make smoke                     # end to end
make gateway GW=litellm        # swap the AI gateway in place
make gateway GW=bifrost
make gateway GW=envoy
make gateway GW=ngf-llmd       # NGF IS the inference gateway (llm-d EPP in path)
make backends PROFILE=full     # add EPP + mock alongside vLLM
make logs-vllm                 # watch the slow CPU load
make logs-epp                  # watch routing decisions
make bench N=50                # gateway overhead, meaningful only on lite
make recreate                  # delete and rebuild the cluster from scratch
make down                      # delete cluster, keep the built image
make orphans                   # check for clusters left under the other runtime
make nuke                      # also delete the registry
```

---

## Gateway modes

| Mode | What sits in the request path | llm-d EPP consulted? | UI |
|---|---|---|---|
| `envoy` | NGF → Envoy AI Gateway → InferencePool → vLLM | **yes**, verified | none (CRDs) |
| `litellm` | NGF → LiteLLM → backends | no (own router) | `/ui/` |
| `bifrost` | NGF → Bifrost → backends | no (own router) | `/` |
| `ngf-llmd` | NGF → InferencePool → vLLM | **broken** — see below | none |

`ngf-llmd`'s EPP integration is a known, reproduced, **not fixed** defect: a
TLS mismatch between NGF's ext_proc client and the EPP means the EPP is never
actually consulted, and `make smoke` cannot detect this because NGF silently
falls back to plain load balancing on ext_proc failure instead of erroring the
request. See "GATEWAY=ngf-llmd looks green but the EPP is never consulted"
below before trusting a passing smoke test for this mode.

`ngf-llmd` is the shortest path: NGF implements the Gateway API Inference
Extension itself, so there is no separate AI gateway tier at all. It needs
`GWAPI_CHANNEL=experimental`, `PROFILE=full` (the EPP only exists there), and
NGF installed with `gwAPIInferenceExtension.enable=true` — which `make up` does.
`GATEWAY=none` remains as an alias.

The two modes that consult the EPP are the ones worth comparing for llm-d
behaviour; LiteLLM and Bifrost bypass it by design, since they do their own
load balancing.

## Observability (Prometheus + Grafana)

Opt-in, because it is the heaviest component in the lab:

```bash
make observability          # kube-prometheus-stack + vLLM's own dashboard
make smoke                  # generate some traffic to graph
```

- **Grafana** `make grafana` → <http://localhost:3000> — login `admin` / `llm-lab`,
  then Dashboards → **vLLM**. Also on <http://localhost:9090> *if* your cluster
  was created with the `30090` mapping (see below).
- **Prometheus** `make prom` → <http://localhost:9091/targets>
- **Remove** `make observability-down` (reclaims ~700 Mi)

Measured cost, from rendering the chart: **704 Mi of requests, 1856 Mi of
limits** across Prometheus (400), Grafana (128), operator (96), kube-state-metrics
(48) and node-exporter (32). Trimmed from the ~2 GB default by disabling
Alertmanager, the admission webhooks, the Windows exporter, persistence, and the
built-in Kubernetes dashboards, and by cutting retention from 10d to 6h.

`make observability` refuses to install below 1200 Mi free and tells you what to
scale down first. The reason it checks: when this node runs out, the API server
drops mid-install and it looks like a chart failure rather than memory.

### Grafana: "failed to load its application files"

**Diagnosed from logs, 2026-08-13. Grafana is not broken — it is starved.**

The message is misleading. Grafana is running, serving, and authenticating; it is
simply answering too slowly for the browser to wait. Observed:

```
path=/                        duration=40.79s
path=/user/auth-tokens/rotate duration=1m0.64s
path=/connections/datasources duration=55.99s
"Database locked, sleeping then retrying" ... SQLITE_BUSY
```

The browser aborts, and Grafana's static fallback page is what you see. The
give-away in the network trace is **zero** requests for JS, CSS or `/api/*` —
the request for `/` never completed, so nothing downstream was ever attempted.
That also rules out the two causes the error text suggests: nothing is proxying,
and a bad `root_url` would produce *failed* asset requests rather than none.

**Cause:** the chart ships **Grafana 13.1.3**, which runs an embedded apiserver,
unified storage, and builds a Bleve search index in memory. This repo originally
requested `50m` CPU / `128Mi` with a `384Mi` cap — sized for Grafana 11. It did
not OOM; it starved, and SQLite on emptyDir then deadlocked against its own
cleanup jobs. vLLM requests 2 of the node's 6 cores, so a 50m pod loses every
scheduling contest.

**Fix (already in `manifests/observability/values.yaml`):** `250m` CPU / `512Mi`
request, `1Gi` limit, plus alerting and analytics disabled. Reapply with:

```bash
make observability
```

Stack memory requests go from ~700 Mi to ~1090 Mi as a result.

If it is still slow, the node is genuinely out of CPU. Scale vLLM to zero while
you use Grafana:

```bash
kubectl -n llm-serving scale deploy/vllm-cpu --replicas=0
```

### Grafana unreachable (connection refused, no page at all)

Different symptom, different cause. If the browser cannot connect at all — as
opposed to Grafana answering with an error page — check that the NodePort is
published:

```bash
podman port llm-lab-control-plane      # or: docker port ...
```

kind applies `extraPortMappings` **only at cluster creation**, so a cluster built
before `30090 -> 9090` existed in `cluster/kind-config.yaml` cannot gain it.
`make grafana` port-forwards and works regardless.

Note the two are easy to confuse: a *slow-starting* Grafana also refuses
connections for the first minute or so, which is not the same as a missing
mapping. Wait for `3/3 Running` before concluding anything.

### Why the PodMonitor matters

The vLLM pods carry `prometheus.io/scrape` annotations, but **the operator
ignores those entirely** — that convention belongs to a hand-written Prometheus
config. The operator discovers targets through `PodMonitor` and `ServiceMonitor`
resources, which is why `manifests/observability/podmonitor-vllm.yaml` exists.
Annotations alone produce zero targets and no error.

The other trap is `podMonitorSelectorNilUsesHelmValues`, which defaults to
**true** and makes the operator select only monitors labelled
`release: <helm-release>`. A PodMonitor without that label is silently skipped.
The values file sets it false, and the PodMonitors carry the label anyway.

Empty panels almost always mean no traffic rather than a broken scrape. Check
<http://localhost:9091/targets> before debugging the dashboard.

## Web UIs

| Gateway | UI | How |
|---|---|---|
| LiteLLM | keys, spend, budgets, logs, model list | <http://localhost:8080/ui/> — **trailing slash required** · login `admin` / `sk-llm-lab-local` |
| Bifrost | config, providers, monitoring | <http://localhost:8080/> |
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

## LiteLLM UI will not load

Use the **trailing slash**: <http://localhost:8080/ui/>

`/ui` without it does not load. LiteLLM answers the slashless form with its own
absolute redirect, and behind this ingress that redirect does not make it back to
the browser. An edge redirect (`/ui` → `/ui/`, exact match) is in
`manifests/ingress/ngf/gateway.yaml`, so after a `make up` either form works.

Login is `admin` / your master key (`sk-llm-lab-local` in this lab) — the
username is **not** the key, which the login page states only in passing.

## "unsupported path: /v1" in the browser

Not an error. `/v1` is a path prefix; the endpoints below it are `/v1/models`,
`/v1/chat/completions`, `/v1/completions`. The gateway is telling you nothing is
routed at exactly `/v1`, which is correct.

Browsable (GET): <http://localhost:8080/v1/models>

Everything else under `/v1` is POST and needs `curl` or `make smoke`.

## Exercises worth doing

These are the reason the lab exists; running it is not the point.

**1. Prove the swap contract holds.** Run `make smoke` under all four gateway modes. Identical assertions, four very different implementations. Then diff what `/v1/models` returns — the differences in how each gateway advertises models are informative.

**2. Watch the Endpoint Picker choose.** `PROFILE=full`, then `make logs-epp` in one pane while you fire concurrent requests in another. `VLLM_REPLICAS` is fixed at 1 on this node's budget, so add mock backends to the pool instead — they emit vLLM-shaped metrics for exactly this:
```bash
kubectl -n llm-serving patch deployment mock-backend --type=json \
  -p='[{"op":"replace","path":"/spec/template/metadata/labels/llm-lab.io~1inference-pool","value":"primary"}]'
```
Send requests sharing a long prefix and grep `make logs-epp` for `director.go:332` / `remainingEndpoints`. **Use `GATEWAY=envoy`, or `/v1/completions` (not `/v1/chat/completions`) under `GATEWAY=ngf-llmd`** — see the `ngf-llmd` entries in Troubleshooting for why chat-completions traffic proves nothing under that gateway right now. Revert the label (`value=mock`) afterward.

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
`nginxGateway.gwAPIInferenceExtension.enable=true` and `...endpointPicker.disableTLS=true`.

**`GATEWAY=ngf-llmd` looks green but the EPP is never consulted** (2026-08-15/16)

`make smoke` passes — real chat completions, real streaming — while `make
logs-epp` shows **zero** scheduling decisions for the traffic that produced
them. This one is dangerous precisely because nothing looks broken.

**Root cause, fully diagnosed:** NGF's `endpoint-picker-shim` container (in
the `llm-ingress-nginx` pod, namespace `llm-gateway`) talks to the EPP over
ext_proc. With `disableTLS=true` (this repo's setting, on the stated but
never-verified assumption that "the EPP serves plaintext gRPC with no
certificate mounted"), the shim speaks plaintext to an EPP that actually
defaults to `secure-serving=true` (GIE v1.5.0 — confirmed in `make logs-epp`'s
"Flags processed" line). Every ext_proc stream fails:

```
error opening ext_proc stream: rpc error: code = Unavailable desc = connection error:
desc = "error reading server preface: EOF"
```

**The trap:** NGF's njs routing (`epp.getEndpoint` in the generated nginx
config) falls back to plain `random two least_conn` load balancing over the
InferencePool's raw Service on *any* ext_proc failure, rather than erroring
the request. So the gateway keeps working — through the fallback, not the
EPP — and `make smoke` cannot tell the difference. Confirmed by adding mock
backends to `primary-pool` (see Exercise 2 below) and watching a 6-request
burst split 4/2 across mocks and vLLM with **no** corresponding entries in
`make logs-epp`.

**Two things were tried and both were rejected — read this before
"fixing" it again:**

1. `disableTLS=false` (the NGF chart's own default) does **not** work either:
   the EPP resets the connection (`connection reset by peer`) because it
   mounts no certificate anywhere in `manifests/scheduler/llm-d/`, so it
   cannot complete a TLS handshake regardless of what the client trusts.
   `skipVerify` only relaxes client-side validation; it cannot make a
   certless server finish a handshake.
2. Symmetric plaintext — `disableTLS=true` **plus** `--secure-serving=false`
   added to the EPP's own args — genuinely fixes NGF (verified: real scheduler
   decisions, `remainingEndpoints: 3` against a 3-endpoint pool, via
   `/v1/completions`) but **breaks `GATEWAY=envoy`**, which is already
   verified working and requires the EPP to stay TLS. Envoy AI Gateway's
   ext_proc client speaks genuine TLS to the same shared EPP and fails a
   plaintext one with `TLS_error: ...WRONG_VERSION_NUMBER`. The two gateways
   want opposite wire protocols from one EPP Deployment with no per-Gateway
   override for it.

**Current state:** left as `disableTLS=true` / EPP default (`secure-serving=
true`), which protects the working `envoy` mode and leaves `ngf-llmd` a known,
reproduced, unfixed defect rather than trading a working mode for a broken
one. Whoever picks this up next: the EPP needs a real certificate (even a
self-signed one NGF trusts via `skipVerify`) so both gateways can speak TLS to
it — that is the fix that doesn't force a choice between the two, and it
was out of scope here.

**Also found while EPP was briefly reachable:** GIE v1.5.0's `openai-parser`
rejects `/v1/chat/completions` (the `messages` array format `make smoke` uses)
with `400 BadRequest - invalid completions request: must have prompt field`.
It only accepts the legacy `/v1/completions` `prompt` field. This is a
**second, separate** defect from the TLS one — even with EPP genuinely
reachable, `make smoke`'s chat-completions check cannot exercise it for
`ngf-llmd`. Use `/v1/completions` (see Exercise 2) to prove EPP scheduling
under this gateway.

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

**`LITELLM_WITH_DB=true` OOMs the node mid-install** (2026-08-15, resolved)

Reproduced twice, same signature both times: `helm upgrade --install litellm
... --wait --timeout 6m` fails with `context deadline exceeded` after watch
streams die (`"unable to decode an event from the watch stream: http2: client
connection lost"`), leaving `Deployment/litellm` at `0/1`.

**Root cause, confirmed via `podman exec llm-lab-control-plane dmesg | grep
oom`:** a genuine, system-wide OOM kill (`constraint=CONSTRAINT_NONE,
global_oom`, `memory.oom.group` — not a per-container limit) that takes out
the migration Job's python/prisma/node subprocesses together. The migration
Job has no memory limit set, and on this 9.7Gi node under `PROFILE=full`
vLLM alone already holds 3-6Gi, leaving too little margin for the transient
spike Postgres + the migration Job + LiteLLM's own boot cause together. This
is failure mode #1 from the original handoff (API server drops mid-install),
not the Postgres-startup race the chart's `migrationJob.extraInitContainers`
hook would fix — the Job itself completes fine once it gets to run.

**Fix that works:** scale vLLM to 0 first, freeing enough headroom for the
install burst, then scale it back up once the release converges:
```bash
kubectl -n llm-serving scale deployment/vllm-cpu --replicas=0
make gateway GW=litellm      # installs clean; migration Job completes on the first attempt
kubectl -n llm-serving scale deployment/vllm-cpu --replicas=1
```
Verified end to end this way: `/ui/` login returns `login=success` with a
`proxy_admin` JWT.

**Why `LITELLM_WITH_DB` still defaults to `false`:** this is a manual
sequencing step, not something `make gateway` automates, so leaving it
`true` as the ambient default would make every *unattended* `make gateway
GW=litellm` (rebuild passes, lifecycle loops, CI-like runs) reproduce the
OOM. Enable it by hand, with the scale-down, when you actually want the
admin UI.

**EPP metrics target `down` with `401 Unauthorized`** (2026-08-15/16)

`http://localhost:9091/targets` shows `podMonitor/.../inference-scheduler`
(or its replacement, see below) unhealthy with a plain 401, which reads like
a broken scrape config rather than an auth requirement.

**Cause:** GIE v1.5.0's EPP runs with `--metrics-endpoint-auth` (confirmed in
`make logs-epp`'s "Flags processed" line) and validates the scrape's bearer
token via TokenReview/SubjectAccessReview — the EPP's own ClusterRole in
`inferencepool.yaml` grants it exactly those two verbs. There is no flag to
turn this off (unlike `--lora-info-metric`).

**Two separate problems, not one:**

1. The obvious fix — `bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token`,
   the same one kube-prometheus-stack's own kubelet/cAdvisor monitors use —
   does not exist on `PodMonitor`'s CRD schema in this Prometheus Operator
   version (`kubectl apply` fails server-side: `unknown field
   spec.podMetricsEndpoints[0].bearerTokenFile`). It is still present,
   deprecated, on `ServiceMonitor`'s schema. `manifests/observability/podmonitor-vllm.yaml`
   now defines the EPP scrape as a `ServiceMonitor` instead — the
   `primary-pool-epp` Service already fronts the right port, so no new
   resource is needed, just the different kind.
2. `ServiceMonitor.spec.selector` matches labels on the **Service** object,
   not the pod-selecting `spec.selector` inside it. The `primary-pool-epp`
   Service had no labels of its own (only its `spec.selector: {app:
   primary-pool-epp}`, which selects pods, not itself), so the ServiceMonitor
   matched zero Services — not a `down` target, no target at all, an even
   quieter failure. Fixed by adding `metadata.labels: {app:
   primary-pool-epp}` to the Service in `inferencepool.yaml`.

Verify both fixed: `curl -sG localhost:9091/api/v1/query --data-urlencode
'query=up{job="primary-pool-epp"}'` should return `1`.

**A source-installed chart reports success even when the install genuinely failed** (2026-08-15/16)

Found while testing `make up` resumability (interrupting mid-`helm install`
and re-running). `scripts/lib.sh`'s `helm_chart_install()` checks the OCI
install's exit code (`if helm_oci upgrade --install ...; then ok ...; fi`)
but the source-install fallback branch did not — it ran `helm upgrade
--install` as a bare statement, then unconditionally printed `ok "...
installed from source"` regardless of whether helm actually succeeded.

**Why `set -euo pipefail` didn't catch it:** callers that try multiple
install methods (NGF: oci → source → manifest) invoke this function as the
condition of their own `if`, e.g. `if "install_ngf_${method}"; then ...`.
Bash suspends `errexit` for every command in a chain being evaluated as an
if/while/until condition, including nested function calls — so the internal
helm failure didn't abort anything, and with no explicit check, execution
fell straight through to the false "installed from source" line. Reproduced
by killing `make up` mid-NGF-install: helm printed `Release ngf has been
cancelled. Error: context canceled` and the very next line was still `[OK]
ngf installed from source`.

**Fix:** the source branch now wraps the helm call in an explicit `if ...;
then ...; return 0; fi` / `return 1`, matching the OCI branch. Confirmed
working correctly on the very next resumability run: a real (unrelated)
source-install failure now correctly fell through to the `manifest` method
instead of being silently swallowed.

**Everything is slow and the Mac is unresponsive**
The VM is swapping. `make status` and look at the memory column. Drop to `PROFILE=standard` or `lite`, or reduce `VLLM_REPLICAS` to 1.
