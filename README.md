# k8s-toolhive-lab

First hands-on day operating Kubernetes: a real local cluster on my own machine,
the core operating vocabulary exercised against live workloads, then Stacklok's
[ToolHive](https://github.com/stacklok/toolhive) Kubernetes operator running **my own
MCP server** ([`@addiplus/vercel-deployment-mcp`](https://www.npmjs.com/package/@addiplus/vercel-deployment-mcp),
listed in the [official MCP registry](https://registry.modelcontextprotocol.io) as
`io.github.addiplus/vercel-deployment-mcp`) behind the operator's proxy, with a real
MCP handshake driven from the host with curl.

Everything in `transcripts/` is captured output from the actual session (2026-08-02).
No fabricated logs. The commit history reflects the real order of work. The lab was
run as a guided session with Claude Code; every command executed for real on this
machine, and the transcripts are the evidence.

## What ran, in one paragraph

Docker background, first Kubernetes: `kind` v0.32.0 created a single-node cluster
(kindest/node:v1.36.1) on Docker Desktop's engine on Windows 11. Phase 2 deployed
nginx and touched every core concept with a live command: Pod vs container,
Deployment and ReplicaSet self-healing, ClusterIP vs NodePort vs port-forward,
Namespaces, ConfigMap and Secret, requests and limits, and pod-to-pod networking
across namespaces. Phase 3 installed the ToolHive operator via Helm (OCI charts),
built my npm-packaged stdio MCP server into a container image with `thv build`,
loaded it into kind, declared it as an `MCPServer` custom resource, and drove the
MCP `initialize` / `tools/list` / `tools/call` sequence from the host through
`kubectl port-forward`, through ToolHive's HTTP proxy, over the operator's SPDY
stdio attach, into the server, out to the Vercel API, and back. A second MCPServer
(Stacklok's packaged docs server, streamable-http) then ran alongside it: two
isolated MCP servers behind two distinct Services under one operator.

## Architecture (as built)

```
Windows 11 host (kind.exe, kubectl.exe, helm.exe, thv.exe, curl)
  └─ Docker Desktop engine (WSL2 backend, named pipe)
       └─ kind node container "toolhive-lab-control-plane" (kindest/node:v1.36.1)
            ├─ control plane pods: kube-apiserver, etcd, kube-scheduler,
            │                      kube-controller-manager
            ├─ cluster plumbing: kindnet (CNI), kube-proxy, CoreDNS
            ├─ namespace lab:    nginx Deployment (3 replicas, ConfigMap-mounted page)
            │                    Services: nginx (ClusterIP), nginx-nodeport (NodePort)
            ├─ namespace lab-b:  client pod (busybox) + its own copy of the Secret
            └─ namespace toolhive-system:
                 ├─ toolhive-operator (Deployment, installed via Helm OCI charts)
                 ├─ MCPServer "vercel-deployment" (transport: stdio)
                 │    ├─ proxy pod (Deployment) ── Service mcp-vercel-deployment-proxy:8080 (/mcp)
                 │    └─ vercel-deployment-0 (StatefulSet)
                 │         └─ image built by: thv build npx://@addiplus/vercel-deployment-mcp
                 │            ENTRYPOINT ["npx", "@addiplus/vercel-deployment-mcp"]
                 │            VERCEL_TOKEN from k8s Secret (dummy value, on purpose)
                 └─ MCPServer "toolhive-docs" (transport: streamable-http)
                      ├─ proxy pod ── Service mcp-toolhive-docs-proxy:8080 (/mcp)
                      └─ docs server pod (ghcr.io/stackloklabs/toolhive-doc-mcp)

host access path for everything: kubectl port-forward (tunnels through the API server)
```

## What I actually learned about isolation

Namespaces isolate **objects** hard and the **network** not at all (by default).
Both halves surprised me relative to Docker intuition:

- A pod in `lab-b` cannot reference a Secret in `lab`. There is no cross-namespace
  `secretKeyRef`. The demo Secret had to be copied into `lab-b` for the client pod
  to consume it (`manifests/14-demo-secret.yaml` shows both copies on purpose, and
  `transcripts/02-core-vocabulary.txt` shows the env var arriving from lab-b's copy).
  Deleting lab's original would not affect the client pod at all.
- Meanwhile the same client pod in `lab-b` fetched nginx in `lab` over the network
  on the first try: `wget http://nginx.lab.svc.cluster.local` returned the
  ConfigMap-served page. The pod network is flat and open across namespaces unless
  a NetworkPolicy blocks it, and kind's default CNI (kindnet) does not even enforce
  NetworkPolicies. Real network isolation requires a policy-capable CNI.
- DNS scoping is name sugar, not a wall: bare `nginx` failed from `lab-b`
  ("bad address", captured in the transcript) because it expands to
  `nginx.lab-b.svc.cluster.local`, while the fully qualified name crossed
  namespaces freely.
- Inside the node, the pod is itself an isolation unit: `crictl` shows a sandbox
  ("pause") pod holding the network namespace that the nginx container joins.
  Containers in a pod share that network identity; pods do not.

ToolHive then applies the same primitives to MCP servers: each server runs in its
own pod (its own cgroup and namespace boundary), gets its own Service, its own
Secret-injected credentials, and clients only ever talk to the proxy, never to the
server pod directly. Running many MCP servers safely is, concretely, namespace and
pod isolation plus a controlled HTTP door per server.

## What I actually learned about networking

Four distinct network layers showed up, and confusing them is the classic beginner
trap:

1. **Pod IPs** (10.244.0.x here): ephemeral, one per pod, gone when the pod dies.
   The self-heal demo proved it: deleting a pod produced a replacement with a new
   name and IP three seconds later.
2. **Service ClusterIP** (10.96.x.x): a stable virtual IP + DNS name in front of
   whatever pods match the label selector. The EndpointSlice listed exactly my three
   nginx pod IPs; kube-proxy programs the balancing. This is the contract that
   survives pod churn.
3. **NodePort**: opens a static port on the node's IP. On kind the "node" is a
   Docker container (172.18.0.2), so NodePort 30080 is reachable from the Docker
   network but not from the Windows host, which teaches the real lesson: NodePort
   binds to node network, wherever that node happens to live.
4. **port-forward**: tunnels through the API server connection, no reachable node
   IP required. That is why it is the default local-dev door, and it is exactly how
   the MCP handshake reached the ToolHive proxy.

The MCP leg stacked one more layer on top: HTTP into the proxy, then the operator's
SPDY-attached stdio into the server process. The dummy-token `tools/call` returning
a Vercel 403 **through the whole chain** was the most instructive single response of
the day: every hop (curl → port-forward → proxy Service → proxy pod → stdio attach →
server → Vercel API → back) had to work for that error to arrive as a structured MCP
`isError` result.

## The ToolHive leg, honestly

- The operator's `MCPServer` CR takes a plain container image. It does **not** run
  `npx://` protocol schemes (that is a `thv` CLI feature). The supported bridge is
  `thv build npx://<pkg> -t <tag>`, then `kind load docker-image <tag>`, then
  referencing the tag with `imagePullPolicy: IfNotPresent`. Researched from live
  docs before installing (`docs/TOOLHIVE_RESEARCH.md`), confirmed by doing it.
- `thv build` generated a sane multi-stage Dockerfile unprompted: node:24-alpine,
  non-root user, npm install of the package, `ENTRYPOINT ["npx", "<pkg>"]`.
- The `VERCEL_TOKEN` Secret carries a dummy value on purpose. The server boots, the
  handshake and `tools/list` succeed without real credentials, and the first real
  tool call fails with a clean Vercel 403. That is the honest boundary of what a
  dummy-token lab proves, and it proves the entire transport chain.
- Helm 4.2.3 handled Stacklok's OCI charts without issues even though the docs
  certify Helm 3.10+ (a fallback to Helm 3 was prepared and never needed).
- The MCPServer status URL reported `/mcp` correctly here; upstream issue #2920
  (status URL showing `/sse` for stdio servers) did not reproduce in this setup.
- `serverInfo.version` from my server reports 0.1.0 while the npm package is 0.2.0;
  that is a bug in my server's own version string, noted for my repo, not ToolHive's.

## Honest scope statement

This was a first hands-on day, on a single-node local kind cluster, on one machine.
It demonstrates operating vocabulary, the ToolHive operator lifecycle, and a real
end-to-end MCP transport chain. It does not demonstrate multi-node scheduling,
production networking (LoadBalancer/Ingress), RBAC design, NetworkPolicy
enforcement, upgrades, or operating anything under load. The Kubernetes screening
claim this repo backs is exactly: stood up a local cluster, learned and exercised
the core concepts including isolation and networking, and ran my own
registry-listed MCP server through ToolHive's Kubernetes operator.

## Repo layout

```
manifests/    every YAML applied, numbered in application order, commented as
              teaching notes (00 namespaces ... 31 second MCPServer)
scripts/      the phase scripts that produced the transcripts (echo-then-run style)
transcripts/  captured command output, per phase (01 cluster-up ... 05 stretch)
docs/         TOOLHIVE_RESEARCH.md: live-docs brief gathered before the operator leg
WORKLOG.md    honest running log of the session, including the plan revision
env.sh        session PATH/KUBECONFIG helper (lab-local kubeconfig, no global state)
```

## Reproduce

Windows 11 + Docker Desktop (or any Docker host; the Windows-specific part is only
where the binaries run):

```bash
source env.sh                                  # or put kind/kubectl/helm/thv on PATH
kind create cluster --name toolhive-lab
bash scripts/phase2-core-vocabulary.sh         # core vocabulary walkthrough
bash scripts/phase3-toolhive-operator.sh       # operator + thv build + MCPServer
bash scripts/phase3b-mcp-handshake.sh          # the handshake receipts
kubectl apply -f manifests/31-docs-mcpserver.yaml   # stretch: second server
kind delete cluster --name toolhive-lab        # teardown
```
