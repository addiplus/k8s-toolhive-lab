# k8s-toolhive-lab — session worklog

Honest running log of the build. Times are local (US Pacific). Nothing in this file is
reconstructed after the fact; entries are appended as the work happens.

## 2026-08-02

- **Session start.** Windows 11 host, Docker Desktop 29.6.2 (linux/amd64 engine, WSL2
  backend), WSL2 with Ubuntu-24.04 (default distro) + docker-desktop utility distro.
  Smart App Control is ON, so the plan avoids unsigned Windows executables entirely:
  all cluster tooling (kubectl, kind, helm) gets installed **inside WSL2 Ubuntu**,
  where SAC is not a factor and official Linux release binaries work as-is.
- **Recon findings:** Docker Desktop healthy, zero containers running (clean window).
  Ubuntu-24.04 had NO Docker WSL integration enabled — `docker` not found inside the
  distro. Network from WSL OK. `/mnt/c` mount OK. Arch x86_64.
- **Cluster path decision: kind inside WSL2 Ubuntu, on the Docker Desktop engine.**
  Tradeoff vs the alternatives: Docker Desktop's built-in Kubernetes is a single
  checkbox but hides the cluster lifecycle (fixed version, no create/delete/kubeconfig
  learning); k3d is fast but runs k3s, whose deviations from upstream can confuse a
  first hands-on day; kind is the CNCF-standard local cluster, matches vanilla
  Kubernetes docs exactly, and lives entirely in Linux containers so Smart App Control
  never enters the picture.
- **Plan revision (honest record):** WSL2 Ubuntu had no Docker integration enabled,
  and enabling it requires a Docker Desktop restart. The restart was prepared, but the
  pre-flight `docker ps` guard found another workload's containers mid-run on this
  machine, and this box's standing rule is "no Docker restarts while other work is
  live." Instead of waiting, tested whether Smart App Control would accept the
  official kind release binary on Windows - it did (reputation-based pass; kind's
  binaries are not Authenticode-signed). So the final path became: **kind v0.32.0 +
  helm v4.2.3 + ToolHive thv v0.41.0 + jq 1.8.2 on the Windows side**, with Docker
  Desktop's already-present signed kubectl v1.36.1, driving the same Linux containers
  through the Docker named pipe. Zero restarts, zero disruption to the other workload.
- **Phase 1 done.** `kind create cluster --name toolhive-lab` -> single control-plane
  node (kindest/node:v1.36.1). Walked nodes, kube-system control-plane pods, kubeconfig
  anatomy, contexts. Transcript: `transcripts/01-cluster-up.txt`.
- **Phase 2 done, all legs first-pass.** Namespaces, ConfigMap->nginx page, Secret
  scoping (had to copy the Secret into lab-b - namespaces isolate objects hard),
  Deployment/ReplicaSet self-heal (replacement pod Running 3s after delete), scale
  1->3, ClusterIP vs NodePort + EndpointSlices, port-forward + curl from Windows,
  cross-namespace DNS success + expected same-ns short-name failure, secret env
  consumption, requests/limits on the node. Transcript:
  `transcripts/02-core-vocabulary.txt`.
- **Phase 3 research (before touching the operator):** live-doc brief saved to
  `docs/TOOLHIVE_RESEARCH.md`. Decisive finding: the operator's MCPServer CR cannot
  run `npx://` (CLI-only); the supported bridge is `thv build npx://<pkg>` ->
  `kind load docker-image` -> plain image reference in the CR.
