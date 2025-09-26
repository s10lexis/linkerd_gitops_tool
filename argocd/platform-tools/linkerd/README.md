# Linkerd via Argo CD (GitHub GitOps Bundle)

This folder lets Argo CD install Linkerd using the official Helm charts, with **dev/staging/prod** values, under the **platform-tools** Argo CD project.

## Layout
```
argocd/platform-tools/linkerd/
  apps/
    linkerd-crds.yaml
    linkerd-control-plane.yaml
  values/
    dev/values.yaml
    staging/values.yaml
    prod/values.yaml
  kustomization.yaml
```

## Create the apps

### Option A — Apply from terminal (simple)
```bash
kubectl apply -k argocd/platform-tools/linkerd
```

### Option B — Parent app in Argo CD UI (pure GitOps)
- Repo URL: your GitHub repo
- Path: argocd/platform-tools/linkerd
- Project: platform-tools (or default)
- Sync Policy: Automated (Prune + Self-heal)
- Directory: Kustomize

## Switch environment
Edit `apps/linkerd-control-plane.yaml` `valueFiles` to one of:
- argocd/platform-tools/linkerd/values/dev/values.yaml
- argocd/platform-tools/linkerd/values/staging/values.yaml
- argocd/platform-tools/linkerd/values/prod/values.yaml

## Identity (mTLS)
Preferred: cert-manager manages a secret (e.g., `linkerd-issuer`) and you reference it with `identity.issuer.existingIssuerSecret`.
Fallback: manual secret:
```bash
kubectl -n linkerd create secret tls linkerd-issuer --cert=tls.crt --key=tls.key
```

## Verify
```bash
kubectl -n linkerd get deploy,pod
# Optional:
linkerd check
```

## Enable injection for apps
```bash
kubectl label namespace my-namespace linkerd.io/inject=enabled --overwrite
```
