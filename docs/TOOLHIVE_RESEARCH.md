# ToolHive + MCP research brief (gathered live 2026-08-02, before Phase 3)

Condensed from live documentation reads the same day as the lab; source URLs at the
bottom. Gathered BEFORE installing anything so the operator leg would follow current
docs, not model memory.

## Headline findings

1. **The ToolHive Kubernetes operator cannot run `npx://` directly.** `spec.image` is a
   required plain container-image reference; protocol schemes (`npx://`, `uvx://`,
   `go://`) are a CLI-only feature of `thv run` / `thv build` (verified against
   `cmd/thv-operator/api/v1beta1/mcpserver_types.go` — zero scheme handling).
   Supported bridge: `thv build npx://<pkg> -t <tag>` → `kind load docker-image <tag>`
   → reference `<tag>` in the MCPServer CR.
2. **MCP spec `2026-07-28` removed the initialize handshake** (stateless, per-request
   `_meta`). ToolHive v0.41.0 is dual-era, so the legacy `2025-06-18` handshake still
   works and is the widest-compat choice for curl probes.
3. **`@addiplus/vercel-deployment-mcp` is stdio-only**, requires `VERCEL_TOKEN`
   (optional `VERCEL_TEAM_ID`), exposes 4 read-only tools: `list_projects`,
   `get_project`, `list_deployments`, `get_deployment`. Maps onto `transport: stdio`.
4. **Known bug stacklok/toolhive#2920:** MCPServer `.status.url` can report `/sse` for a
   stdio server proxied as streamable-http when the real path is `/mcp`. Probe both.

## Operator install (docs.stacklok.com/toolhive/guides-k8s/deploy-operator-helm)

```bash
helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds \
  -n toolhive-system --create-namespace
helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator \
  -n toolhive-system --create-namespace
kubectl get pods -n toolhive-system   # operator ready in ~30s
```

Docs state Helm "v3.10 minimum, v3.14+ recommended"; Helm 4 is not (yet) certified by
Stacklok — if the OCI install misbehaves under Helm 4, fall back to Helm v3.21.x.

## MCPServer CRD essentials (group `toolhive.stacklok.dev`, version `v1beta1`)

- `image` (required, plain reference), `transport` ∈ stdio|streamable-http|sse
  (default stdio), `proxyMode` ∈ sse|streamable-http (default streamable-http;
  stdio-only setting), `proxyPort` (default 8080), `args`, `env` (name/value),
  `secrets` (name/key/targetEnvName → k8s Secret), `permissionProfile`
  (builtin: none|network), `podTemplateSpec` (raw pod-spec patch; the MCP container
  must be named exactly `mcp`), `resources` (flat `{cpu, memory}` strings, not the
  standard k8s map).
- `spec.volumes` is hostPath-only; use `podTemplateSpec` for emptyDir/configMap.
- stdio handling: operator runs a proxyrunner pod + the server as a StatefulSet,
  attaches to stdio via SPDY streams, HTTP proxy converts HTTP ⇄ JSON-RPC.
- Service naming: `service/mcp-<name>-proxy`, port = proxyPort. Non-MCP `/health`
  endpoint available.
- SECURITY (quoted from source): with no auth configured "the proxy runs
  UNAUTHENTICATED. It accepts every request that can reach its port" — fine for a
  local lab behind port-forward, never for real exposure.

## MCP handshake for curl probes (legacy 2025-06-18 against /mcp)

1. POST `initialize` with `Accept: application/json, text/event-stream` (both REQUIRED
   or the server may 406), body `protocolVersion: 2025-06-18`.
2. Capture optional `Mcp-Session-Id` response header; include on subsequent requests
   only if non-empty.
3. POST `notifications/initialized` (no id) → expect 202.
4. POST `tools/list` → strip SSE `data:` framing before jq (same endpoint may answer
   with either JSON or SSE framing).

## Pitfalls carried into the lab plan

- `kind load docker-image` is mandatory for locally-built images (kind nodes cannot
  see the host daemon's images) + `imagePullPolicy: IfNotPresent` via podTemplateSpec.
- Headers + body must be captured separately (`curl -D hdr -o body`) or jq chokes.
- Skipping `notifications/initialized` stalls many legacy-era servers.
- stdio MCP servers support a single client connection at a time.

## Sources

docs.stacklok.com/toolhive (guides-k8s: quickstart, deploy-operator-helm, run-mcp-k8s;
guides-cli: build-containers, install; reference: crds/mcpserver, cli/thv_run,
cli/thv_build) · raw.githubusercontent.com/stacklok/toolhive/main/cmd/thv-operator/api/v1beta1/mcpserver_types.go ·
github.com/stacklok/toolhive/issues/2920 · registry.npmjs.org/@addiplus%2Fvercel-deployment-mcp ·
github.com/addiplus/vercel-deployment-mcp README · registry.modelcontextprotocol.io
(v0/servers?search=vercel-deployment) · modelcontextprotocol.io/specification
(versioning, 2026-07-28 changelog + streamable-http, 2025-11-25 transports,
2025-06-18 lifecycle) · kind v0.32.0 release notes · helm.sh install docs
