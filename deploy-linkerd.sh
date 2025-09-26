#!/bin/bash
set -eo pipefail

# === CONFIG ===
NAMESPACE="linkerd"
APP_PATH="argocd/platform-tools/linkerd"
VALUES_ENV="dev"                  # dev | staging | prod
USE_CERT_MANAGER="true"           # "true" or "false"
CERT_MANAGER_VERSION="v1.14.5"
TARGET_NS_FOR_INJECTION="default"

section () { echo -e "\n\033[1;36m==> $1\033[0m"; }

# === Pre-flight checks (tolerant) ===
section "Pre-flight checks"

KUBECTL="$(command -v kubectl || true)"
echo "kubectl path: ${KUBECTL:-<not found>}"
echo "PATH: $PATH"

if [ -z "$KUBECTL" ]; then
  echo "❌ kubectl not found in PATH"; exit 1
fi

# (skip running 'kubectl version' — some environments return non-zero)
# Just show it (best-effort) and continue
"$KUBECTL" version --client || echo "ℹ️  kubectl client printed above (ignoring exit code)"

# context must be docker-desktop
CTX="$("$KUBECTL" config current-context 2>/dev/null || true)"
echo "current-context: ${CTX:-<none>}"
if [ "$CTX" != "docker-desktop" ]; then
  echo "❌ Current context is '$CTX' (expected 'docker-desktop')."
  echo "   Run: kubectl config use-context docker-desktop"
  exit 1
fi

# cluster reachable?
if ! "$KUBECTL" get nodes >/dev/null 2>&1; then
  echo "❌ Cannot reach the cluster (is Docker Desktop Kubernetes running?)."; exit 1
fi

VALUES_FILE="$APP_PATH/values/$VALUES_ENV/values.yaml"
[ -f "$VALUES_FILE" ] || { echo "❌ Missing $VALUES_FILE"; exit 1; }
echo "✅ Pre-flight OK | values: $VALUES_FILE"

# === Apply Argo CD Applications ===
section "Applying Argo CD Applications (CRDs + control plane)"
"$KUBECTL" apply -k "$APP_PATH"
sleep 10

# === Ensure namespace ===
section "Ensuring namespace '$NAMESPACE'"
"$KUBECTL" get ns "$NAMESPACE" >/dev/null 2>&1 || "$KUBECTL" create ns "$NAMESPACE"

# === Certificates (cert-manager mode by default) ===
if [ "$USE_CERT_MANAGER" = "true" ]; then
  section "CERT-MANAGER MODE"
  "$KUBECTL" get ns cert-manager >/dev/null 2>&1 || "$KUBECTL" create ns cert-manager
  if ! "$KUBECTL" -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
    "$KUBECTL" apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    "$KUBECTL" -n cert-manager rollout status deploy/cert-manager --timeout=300s
    "$KUBECTL" -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s
    "$KUBECTL" -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
  fi

  section "Creating self-signed root CA and Linkerd issuer"
  cat <<'EOF' | "$KUBECTL" apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: cert-manager
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: linkerd-root-ca
  secretName: root-ca
  duration: 87600h
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
EOF

  for i in {1..60}; do
    "$KUBECTL" -n cert-manager get secret root-ca >/dev/null 2>&1 && break
    sleep 2
  done

  cat <<EOF | "$KUBECTL" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: root-ca
  namespace: ${NAMESPACE}
type: kubernetes.io/tls
data:
  tls.crt: $("$KUBECTL" -n cert-manager get secret root-ca -o jsonpath='{.data.tls\.crt}')
  tls.key: $("$KUBECTL" -n cert-manager get secret root-ca -o jsonpath='{.data.tls\.key}')
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: linkerd-ca-issuer
  namespace: ${NAMESPACE}
spec:
  ca:
    secretName: root-ca
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: linkerd-issuer
  namespace: ${NAMESPACE}
spec:
  isCA: true
  commonName: identity.linkerd.cluster.local
  duration: 2160h
  renewBefore: 360h
  secretName: linkerd-issuer
  privateKey:
    algorithm: RSA
    size: 2048
  usages: ["cert sign","crl sign"]
  issuerRef:
    name: linkerd-ca-issuer
    kind: Issuer
EOF

  section "Patching values.yaml with trustAnchorsPEM + existingIssuerSecret"
  "$KUBECTL" -n cert-manager get secret root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/linkerd-root-ca.crt
  PEM_INDENTED=$(sed 's/^/  /' /tmp/linkerd-root-ca.crt)
  awk -v repl="$PEM_INDENTED" '
    $1=="trustAnchorsPEM:" {print "trustAnchorsPEM: |\n"repl; skip=1; next}
    skip==1 && $0 ~ /^ *$/ {skip=0}
    skip!=1 {print}
  ' "$VALUES_FILE" > /tmp/values.lnk && mv /tmp/values.lnk "$VALUES_FILE"

  if grep -qE '^[[:space:]]*#?[[:space:]]*existingIssuerSecret:' "$VALUES_FILE"; then
    sed -i 's/^ *#\? *existingIssuerSecret:.*/    existingIssuerSecret: linkerd-issuer/' "$VALUES_FILE"
  else
    sed -i '/^identity:/{n;/^[[:space:]]*issuer:/{n;a\ \ \ \ existingIssuerSecret: linkerd-issuer\n}}' "$VALUES_FILE"
  fi
fi

# === Nudge Argo CD to reconcile ===
section "Trigger reconciliation"
"$KUBECTL" -n argocd annotate app linkerd-crds \
  "reconcile.argocd.argoproj.io/requested-by=$(whoami)-$(date +%s)" --overwrite || true
"$KUBECTL" -n argocd annotate app linkerd-control-plane \
  "reconcile.argocd.argoproj.io/requested-by=$(whoami)-$(date +%s)" --overwrite || true

# === Wait and verify ===
section "Waiting for Linkerd control plane"
sleep 20
"$KUBECTL" -n "$NAMESPACE" wait --for=condition=available deploy --all --timeout=600s || true
"$KUBECTL" -n "$NAMESPACE" get deploy,pod || true

if command -v linkerd >/dev/null 2>&1; then
  section "Running linkerd check"
  linkerd check || true
fi

# === Enable injection ===
section "Enable sidecar injection in '$TARGET_NS_FOR_INJECTION'"
"$KUBECTL" label namespace "$TARGET_NS_FOR_INJECTION" linkerd.io/inject=enabled --overwrite

echo -e "\n🎉 DONE — Linkerd installed with mTLS. Values patched for: $VALUES_ENV"

