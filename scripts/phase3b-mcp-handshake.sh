#!/usr/bin/env bash
# Phase 3b - drive a REAL MCP handshake from the host, through kubectl
# port-forward, through ToolHive's proxy, over SPDY-attached stdio, into the
# npm-packaged server. Legacy handshake (protocolVersion 2025-06-18) because
# ToolHive v0.41.0 is dual-era and it's the widest-compat curl target.
#   source env.sh && bash scripts/phase3b-mcp-handshake.sh 2>&1 | tee -a transcripts/04-mcp-handshake.txt
set -uo pipefail

say() { echo; echo "# $*"; }
MCP_URL="http://localhost:18090/mcp"
PV="2025-06-18"
HDR=$(mktemp); BODY=$(mktemp)

say "=== PHASE 3b: MCP initialize handshake against the operator-run server ==="

say "--- port-forward the proxy Service (naming convention: mcp-<name>-proxy) ---"
kubectl get service -n toolhive-system
kubectl port-forward service/mcp-vercel-deployment-proxy 18090:8080 -n toolhive-system >/tmp/pf-mcp.log 2>&1 &
PF_PID=$!
echo "(port-forward backgrounded, pid $PF_PID)"

say "--- health endpoint first ---"
echo "\$ curl -sS --retry 20 --retry-delay 1 --retry-connrefused http://localhost:18090/health"
curl -sS --retry 20 --retry-delay 1 --retry-connrefused http://localhost:18090/health; echo

say "--- STEP 1: initialize (headers and body captured separately) ---"
echo "\$ curl -X POST $MCP_URL -d '{initialize, protocolVersion: $PV, clientInfo: k8s-toolhive-lab-probe}'"
curl -sS -X POST "$MCP_URL" -D "$HDR" -o "$BODY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
        "protocolVersion":"'"$PV"'","capabilities":{},
        "clientInfo":{"name":"k8s-toolhive-lab-probe","title":"Lab curl probe","version":"1.0.0"}}}'
echo "--- response headers ---"; cat "$HDR"
echo "--- response body ---"; cat "$BODY"; echo

SESSION_ID=$(grep -i '^mcp-session-id:' "$HDR" | tail -1 | cut -d: -f2- | tr -d ' \r\n' || true)
NEG_PV=$(sed -e 's/^data: //' -e '/^event: /d' -e '/^:/d' "$BODY" | grep -v '^[[:space:]]*$' | jq -r '.result.protocolVersion // empty' | tail -1)
[ -n "$NEG_PV" ] && PV="$NEG_PV"
say "negotiated: protocolVersion=[$PV] session=[${SESSION_ID:-none}]"
SESSION_ARGS=(); [ -n "$SESSION_ID" ] && SESSION_ARGS=(-H "Mcp-Session-Id: ${SESSION_ID}")

say "--- STEP 2: notifications/initialized (expect 202) ---"
curl -sS -i -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: ${PV}" "${SESSION_ARGS[@]}" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
echo

say "--- STEP 3: tools/list - the server's real tool inventory ---"
curl -sS -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: ${PV}" "${SESSION_ARGS[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sed -e 's/^data: //' -e '/^event: /d' -e '/^id: /d' -e '/^:/d' \
  | grep -v '^[[:space:]]*$' | jq '.result.tools[] | {name, description}'

say "--- STEP 4: call a tool WITH THE DUMMY TOKEN - expecting a Vercel auth error,"
say "    which itself proves the full path: HTTP -> proxy -> stdio -> server -> Vercel API ---"
curl -sS -X POST "$MCP_URL" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -H "MCP-Protocol-Version: ${PV}" "${SESSION_ARGS[@]}" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_projects","arguments":{"limit":1}}}' \
  | sed -e 's/^data: //' -e '/^event: /d' -e '/^id: /d' -e '/^:/d' \
  | grep -v '^[[:space:]]*$' | jq '.result // .error'

kill $PF_PID 2>/dev/null
rm -f "$HDR" "$BODY"
say "=== PHASE 3b COMPLETE ==="
