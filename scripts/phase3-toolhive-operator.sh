#!/usr/bin/env bash
# Phase 3a - install the ToolHive operator (Helm, per Stacklok docs read live
# 2026-08-02), build the npx-based MCP server into a real image with thv build,
# load it into kind, and create the MCPServer custom resource.
#   source env.sh && bash scripts/phase3-toolhive-operator.sh 2>&1 | tee -a transcripts/03-toolhive-operator.txt
set -uo pipefail

run() { echo; echo "\$ $*"; "$@"; }
say() { echo; echo "# $*"; }

say "=== PHASE 3a: ToolHive operator + MCPServer CR ==="

run helm version
say "Note: Helm 4 - ToolHive docs certify v3.10+; if OCI install misbehaves we fall back to Helm 3."

say "--- Operator install (two OCI charts: CRDs, then the operator) ---"
run helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds -n toolhive-system --create-namespace
run helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator -n toolhive-system --create-namespace

say "--- What did that install? ---"
echo "\$ kubectl get crd | grep toolhive"
kubectl get crd | grep toolhive
run kubectl -n toolhive-system get deployments
run kubectl wait --for=condition=Available deployment --all -n toolhive-system --timeout=300s
run kubectl -n toolhive-system get pods

say "--- Build the npx package into a container image (operator can't run npx:// directly) ---"
run thv version
run thv build npx://@addiplus/vercel-deployment-mcp -t vercel-deployment-mcp:0.2.0
echo "\$ docker images vercel-deployment-mcp"
docker images vercel-deployment-mcp

say "--- Load the local image into the kind node (nodes cannot see the host daemon's images) ---"
run kind load docker-image vercel-deployment-mcp:0.2.0 --name toolhive-lab

say "--- Secret for VERCEL_TOKEN: DUMMY value, on purpose (handshake proves out; real API calls will fail auth) ---"
echo "\$ kubectl -n toolhive-system create secret generic vercel-token --from-literal=token=DUMMY ..."
kubectl -n toolhive-system create secret generic vercel-token \
  --from-literal=token=dummy-lab-token-not-real \
  --dry-run=client -o yaml | kubectl apply -f -

say "--- Create the MCPServer custom resource ---"
run kubectl apply -f manifests/30-vercel-mcpserver.yaml
run kubectl get mcpservers -n toolhive-system

say "--- Give the operator a moment, then inspect EVERYTHING it created ---"
kubectl wait --for=jsonpath='{.status.phase}'=Running mcpserver/vercel-deployment -n toolhive-system --timeout=180s \
  || kubectl wait --for=jsonpath='{.status.phase}'=Ready mcpserver/vercel-deployment -n toolhive-system --timeout=60s \
  || echo "MCPServer not Running/Ready yet - dumping state below either way"
run kubectl get mcpservers -n toolhive-system -o wide
run kubectl get all -n toolhive-system
run kubectl describe mcpserver vercel-deployment -n toolhive-system

say "=== PHASE 3a COMPLETE (see 03b for the MCP handshake) ==="
