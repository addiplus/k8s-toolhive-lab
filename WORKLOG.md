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
