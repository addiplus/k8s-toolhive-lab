#!/usr/bin/env bash
# Phase 2 - core Kubernetes vocabulary, hands on. Run from the lab root:
#   source env.sh && bash scripts/phase2-core-vocabulary.sh 2>&1 | tee -a transcripts/02-core-vocabulary.txt
# Every command is echoed before it runs; nothing here is simulated.
set -uo pipefail

run() { echo; echo "\$ $*"; "$@"; }
say() { echo; echo "# $*"; }

say "=== PHASE 2: core vocabulary against the live cluster ==="

say "--- Namespaces: the isolation boundary for names and objects ---"
run kubectl apply -f manifests/00-namespaces.yaml
run kubectl get namespaces

say "--- ConfigMap + Secret objects first (the Deployment mounts them) ---"
run kubectl apply -f manifests/10-nginx-configmap.yaml
run kubectl apply -f manifests/14-demo-secret.yaml
say "Secrets are namespace-scoped: same value had to be created TWICE (lab and lab-b)"
say "because a pod can only reference Secrets in its own namespace."
run kubectl get secret -n lab demo-credentials -o yaml

say "--- Deployment -> ReplicaSet -> Pod: the ownership chain ---"
run kubectl apply -f manifests/11-nginx-deployment.yaml
run kubectl rollout status deployment/nginx -n lab --timeout=180s
run kubectl get deployments,replicasets,pods -n lab -o wide --show-labels

say "--- Pod vs container: the node's container runtime sees MORE than kubectl ---"
say "kubectl shows the pod; crictl inside the kind node shows the actual containers"
say "(including the 'pause' sandbox container that holds the pod's network namespace)."
run docker exec toolhive-lab-control-plane crictl pods --name nginx
run docker exec toolhive-lab-control-plane crictl ps --name nginx

say "--- Self-healing: delete a pod, the ReplicaSet replaces it ---"
VICTIM=$(kubectl get pods -n lab -l app=nginx -o jsonpath='{.items[0].metadata.name}')
say "victim pod: $VICTIM"
run kubectl delete pod "$VICTIM" -n lab --wait=false
run kubectl get pods -n lab
run kubectl wait --for=condition=Ready pod -l app=nginx -n lab --timeout=120s
run kubectl get pods -n lab
say "Same labels, NEW pod name/IP - identity lives in the Service, not the pod."

say "--- Scale: one field change, the controller does the rest ---"
run kubectl scale deployment/nginx -n lab --replicas=3
run kubectl rollout status deployment/nginx -n lab --timeout=180s
run kubectl get pods -n lab -o wide

say "--- Services: ClusterIP (in-cluster) vs NodePort (on the node) ---"
run kubectl apply -f manifests/12-nginx-service-clusterip.yaml
run kubectl apply -f manifests/13-nginx-service-nodeport.yaml
run kubectl get services -n lab
run kubectl get endpointslices -n lab
say "The EndpointSlice lists the 3 pod IPs behind the Service - kube-proxy programs"
say "the virtual IP to balance across exactly these."

say "--- port-forward: the local-dev door (tunnels through the API server) ---"
kubectl port-forward service/nginx 18080:80 -n lab >/tmp/pf-nginx.log 2>&1 &
PF_PID=$!
echo "\$ kubectl port-forward service/nginx 18080:80 -n lab  (backgrounded, pid $PF_PID)"
run curl -sS --retry 15 --retry-delay 1 --retry-connrefused http://localhost:18080/
kill $PF_PID 2>/dev/null
say "That HTML came from the ConfigMap, through the Service, through the tunnel."
say "NodePort 30080 is bound on the kind node CONTAINER (172.18.0.2) - reachable from"
say "the Docker network, not from this Windows host; port-forward is the local path."

say "--- Pod-to-pod networking + cross-namespace DNS ---"
run kubectl apply -f manifests/20-client-pod.yaml
run kubectl wait --for=condition=Ready pod/client -n lab-b --timeout=120s
say "client pod in lab-b curls nginx in lab through the Service DNS name:"
run kubectl exec -n lab-b client -- wget -qO- http://nginx.lab.svc.cluster.local
say "Short name WITHOUT namespace resolves only inside the same namespace:"
echo "\$ kubectl exec -n lab-b client -- wget -qO- -T 3 http://nginx  (expected to FAIL)"
kubectl exec -n lab-b client -- wget -qO- -T 3 http://nginx || echo "FAILED AS EXPECTED: 'nginx' alone means nginx.lab-b, which does not exist"
say "LESSON: namespaces isolate OBJECTS hard (secrets, names) but the pod network is"
say "flat and open by default - cross-namespace traffic flows unless a NetworkPolicy"
say "(with a policy-enforcing CNI - kind's default kindnet does NOT enforce) blocks it."

say "--- Secret consumption + the isolation asymmetry ---"
run kubectl exec -n lab-b client -- printenv DEMO_API_KEY
say "That value came from lab-b's COPY of the secret. The original in 'lab' is"
say "invisible to this pod - deleting lab-b's copy breaks it, lab's copy is irrelevant."

say "--- Resource requests vs limits: scheduler math vs cgroup ceiling ---"
run kubectl describe node toolhive-lab-control-plane
say "(see 'Allocated resources' above: requests drive scheduling; limits cap usage)"
say "kubectl top is unavailable here on purpose: kind ships no metrics-server by default."

say "=== PHASE 2 COMPLETE ==="
