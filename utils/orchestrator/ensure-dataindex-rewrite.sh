#!/bin/bash
#
# Deploy osl-di-rewrite in front of Data Index and point app-config-oidc at it.
# Usage: ./utils/orchestrator/ensure-dataindex-rewrite.sh <namespace>
#
set -euo pipefail

ns="${1:-}"
[[ -n "$ns" ]] || { echo "Error: namespace required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
name="osl-di-rewrite"
rewrite_url="http://${name}.${ns}.svc.cluster.local"
js="${SCRIPT_DIR}/utils/orchestrator/osl-di-rewrite.js"
[[ -f "$js" ]] || { echo "Error: missing ${js}" >&2; exit 1; }

image="$(oc get deploy redhat-developer-hub -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
[[ -n "$image" ]] || { echo "Error: cannot resolve RHDH image for data-index rewrite proxy" >&2; exit 1; }

echo "==> ensuring data-index rewrite proxy ${name} -> sonataflow-platform-data-index-service"
current_url="$(oc get configmap app-config-oidc -n "$ns" -o jsonpath='{.data.app-config-oidc\.yaml}' 2>/dev/null | awk '/url:/ {print $2; exit}')"
if oc get deploy "$name" -n "$ns" >/dev/null 2>&1 && [[ "$current_url" == "$rewrite_url" ]]; then
    oc rollout status "deploy/${name}" -n "$ns" --timeout=180s >/dev/null
    echo "==> data-index rewrite proxy already configured (${rewrite_url})"
    exit 0
fi
oc create configmap "$name" \
    --from-file=osl-di-rewrite.js="$js" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      containers:
        - name: rewrite
          image: ${image}
          command: ["node", "/opt/app-root/src/osl-di-rewrite.js"]
          env:
            - name: OSL_DI_UPSTREAM
              value: http://sonataflow-platform-data-index-service.${ns}.svc.cluster.local
            - name: PORT
              value: "8080"
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            tcpSocket:
              port: 8080
            periodSeconds: 5
          volumeMounts:
            - name: script
              mountPath: /opt/app-root/src/osl-di-rewrite.js
              subPath: osl-di-rewrite.js
      volumes:
        - name: script
          configMap:
            name: ${name}
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - name: http
      port: 80
      targetPort: 8080
EOF
oc rollout status "deploy/${name}" -n "$ns" --timeout=180s >/dev/null
oidc_tmp="$(mktemp)"
oc get configmap app-config-oidc -n "$ns" -o jsonpath='{.data.app-config-oidc\.yaml}' > "$oidc_tmp"
awk -v url="$rewrite_url" '
    BEGIN { done = 0 }
    {
        if (!done && $0 ~ /^[[:space:]]*url:/) {
            match($0, /^[[:space:]]*/)
            print substr($0, 1, RLENGTH) "url: " url
            done = 1
            next
        }
        print
    }
' "$oidc_tmp" > "${oidc_tmp}.new"
mv "${oidc_tmp}.new" "$oidc_tmp"
oc create configmap app-config-oidc \
    --from-file=app-config-oidc.yaml="$oidc_tmp" \
    -n "$ns" --dry-run=client -o yaml | oc apply -f - >/dev/null
rm -f "$oidc_tmp"
oc rollout restart "deploy/redhat-developer-hub" -n "$ns" >/dev/null
oc rollout status "deploy/redhat-developer-hub" -n "$ns" --timeout=300s >/dev/null
echo "==> data-index rewrite proxy ready (${rewrite_url})"
