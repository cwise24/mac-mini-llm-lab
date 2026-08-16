# Handoff to Claude Code

Paste this into Claude Code from inside this directory.

---

## Context

Kubernetes LLM serving lab on an Apple Silicon Mac mini. **kind on podman**, NGINX
Gateway Fabric ingress, three swappable AI gateways, llm-d scheduling plane.
Read `docs/HomeLab_Architecture_v1.md` first — especially section 5, which states
what is genuinely real here and what is simulated.

## Environment facts that are NOT negotiable

- **podman, not docker.** `KIND_EXPERIMENTAL_PROVIDER=podman`, rootful machine,
  6 CPU / ~9.9 GB allocatable. Host is reachable as `host.containers.internal`.
- **Helm v4 on this machine cannot pull OCI charts from ghcr.io** (403 on the
  token endpoint). docker.io OCI works; curl to ghcr works. Diagnosed but not
  root-caused — see `make doctor-registry`, steps 2/5/8/9. Do not spend time on
  it. In practice only NGF is affected and it falls back to git source
  automatically; Envoy Gateway and Envoy AI Gateway install fine from docker.io
  OCI. LiteLLM and Bifrost are git-source-only because no OCI package exists at
  all. A `403: denied` for `ghcr.io/nginx/charts/...` in `make up` is EXPECTED —
  the line that matters is the `NGF installed via source` immediately after.
- **Container image pulls from ghcr work fine** (containerd, different client).
  Only helm's chart pull is affected.
- No GPU. In-cluster inference is CPU-only and slow by design.
- **arm64 is a real constraint on images, not a formality.** The upstream GIE
  endpoint picker is amd64-only and dies under emulation inside the Go runtime
  (`lfstack.push invalid packing`), so `EPP_IMAGE` is llm-d's build. Run
  `make verify-images` before blaming anything else for a crashloop.

## Current state — validated 2026-08-10

All four gateway modes pass `make smoke` (ingress, models, chat completion with
non-empty content, SSE streaming), consecutively, on `PROFILE=full` with real
in-cluster vLLM inference:

| Mode | Status | Notes |
|---|---|---|
| `GW=litellm` | pass | |
| `GW=bifrost` | pass | |
| `GW=envoy`   | pass | EPP genuinely in the request path — see below |
| `GW=none`    | pass | NGF -> InferencePool -> EPP directly |

Lifecycle proven: `make down && make up && make backends && make gateway
GW=envoy && make smoke` is green, `make rebuild` exits 0, and all four modes
still swap cleanly afterwards.

**`GW=envoy` now really does keep the EPP in the request path.** It previously
did not — the `AIServiceBackend` pointed at `Service/vllm-cpu`, so Envoy
round-robined over EndpointSlice members and llm-d was installed but inert. It
now references the InferencePool, verified two ways: the generated HTTPRoute
reports `ResolvedRefs=True` against `llm-serving/primary-pool`, and while the
mocks were briefly pool members a request for the real model came back
`[mock reply from mock-fast]` — only reachable via EPP endpoint selection.

### Known-good but worth knowing

- **The EPP logs one error per scrape**, `extract failed ...
  vllm:lora_requests_info not found`. Harmless and expected: vLLM only registers
  that metric with LoRA enabled. Metrics still commit, the endpoint never goes
  stale. `--lora-info-metric` is hard-REJECTED in GIE v1.5.0, so silencing it
  would mean restating the whole `EndpointPickerConfig`. Do not chase it.
- **`kind get clusters` errors out** under kind v0.32.0 + podman 6.0.2 (podman 6
  changed `.Labels` in `ps` from a map to a slice). Cosmetic — `cluster_exists()`
  falls back to container labels and `kind create/delete` are fine. Unfixed.
- **Only `PROFILE=full` has been exercised.** `lite` and `standard` are untested
  surface. Note that `GW=none` and `GW=envoy` cannot work under either, because
  neither profile deploys the InferencePool.

### Not exercised at all

`make bench`, `make nuke`, `make build-vllm`, `make preload-images`,
`make versions`, `make doctor-registry`.

## Where the bodies are buried

Failures in this stack overwhelmingly present as *something else*. The full
detail is in `docs/HomeLab_Runbook_v1.md`; the pattern worth internalising:

- **NGF forbids HTTPRoute rule `timeouts`** and still reports the route
  `Accepted`, hiding the refusal in a condition message. Timeouts and response
  buffering live in the `ProxySettingsPolicy` in `manifests/ingress/ngf/`.
- **Envoy Gateway rejects the InferencePool group** unless it is registered via
  `extensionManager.backendResources`, and logs that only in the controller.
- **Helm silently ignores unknown values keys**, so a wrong schema path (Bifrost
  `storage.enabled` vs `storage.persistence.enabled`) does exactly nothing.
- **vLLM 0.26 prefix-matches `--device=cpu`** onto `--device-ids` and fails deep
  in engine config with `Non-integer device ID 'cpu'`, not "unknown flag".
- **The upstream GIE endpoint picker is amd64-only** at every tag; `EPP_IMAGE`
  points at llm-d's arm64 build. `make verify-images` catches this.

When something 500s or hangs, read resource *status conditions* and controller
logs before touching config — every one of the above was invisible from the
manifest alone.

## Suggested next work

1. **`make bench` across all four modes** on `PROFILE=lite`, where the backend is
   zero-latency and you are measuring only proxy overhead. This is the
   comparison the swappable design exists for and it has never been run.
2. **Validate `PROFILE=lite` and `standard`**, including what `GW=envoy`/`none`
   should do when no InferencePool exists — currently they would simply fail.
3. **Watch the EPP actually choose** (`docs/HomeLab_Runbook_v1.md`, exercise 2):
   raise `VLLM_REPLICAS` only alongside VM memory, then send prefix-sharing
   concurrent requests and watch `make logs-epp` converge on one endpoint.

## Runtime and cleanup

`CONTAINER_CLI` in `.env` selects podman or docker; `KIND_EXPERIMENTAL_PROVIDER`
and `HOST_INTERNAL_NAME` are DERIVED in lib.sh and must not be set by hand.

Always `make down` before `make use-docker` / `make use-podman`. kind clusters do
not survive a runtime switch — they are orphaned silently, still consuming disk
and port 8080 while invisible to kind. The switch targets refuse unless the
cluster is gone (`FORCE=1` overrides). `make orphans` audits both runtimes.

## Ground rules

- Fix root causes in the repo, not by hand in the cluster. Every fix must
  survive `make rebuild`.
- Verify upstream before pinning a version, a chart path, a values key or a CLI
  flag. This is *the* recurring defect in this repo — the 2026-08-10 pass alone
  turned up a dozen more, and several were invisible because the tool accepted
  the input and ignored it. Reading the actual `values.yaml`, CRD schema or
  `api/*.go` at the pinned tag costs seconds; `curl -o /dev/null -w
  '%{http_code}'` against the raw URL costs two.
- Comment the *why* on anything non-obvious, matching the existing style.
- `VLLM_REPLICAS=1` on this box — now the default in `.env`. Two do not fit, and
  raising it also breaks the `Recreate` headroom assumption in the vLLM manifest.
- Never delete files.

## Useful

```bash
make help
make capture            # full diagnostics -> diagnostics.log
make doctor-registry    # registry failure triage
make versions           # pinned vs upstream latest
make status
```
