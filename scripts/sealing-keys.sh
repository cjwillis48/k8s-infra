#!/usr/bin/env bash
# Back up / restore the Sealed Secrets private keys. Without them, a rebuilt
# cluster gets a fresh key and every *.sealed.yml in git is undecryptable.
#
#   backup  — export all sealing keys to $SEALING_KEYS (PLAINTEXT private keys:
#             move a copy into the password manager, never into git)
#   restore — apply them to kube-system; run BEFORE the controller is installed.
#             Fails if the file is missing, unless ALLOW_NEW_SEALING_KEY=1.
set -euo pipefail

SEALING_KEYS="${SEALING_KEYS:-$HOME/.config/homie/sealed-secrets-keys.json}"
export KUBECONFIG="${KUBECONFIG:-kubeconfig}"
LABEL=sealedsecrets.bitnami.com/sealed-secrets-key

case "${1:-}" in
  backup)
    mkdir -p "$(dirname "$SEALING_KEYS")"
    umask 077
    kubectl -n kube-system get secret -l "$LABEL" -o json > "$SEALING_KEYS"
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$SEALING_KEYS")
    echo "Wrote $n sealing key(s) to $SEALING_KEYS (mode 600)."
    echo "Store a copy in the password manager. Re-run only if a new key is ever added."
    ;;
  restore)
    if [[ ! -f $SEALING_KEYS ]]; then
      if [[ ${ALLOW_NEW_SEALING_KEY:-} == 1 ]]; then
        echo "WARNING: no $SEALING_KEYS; controller will generate a NEW key." >&2
        echo "WARNING: every existing *.sealed.yml must be re-sealed from plaintext." >&2
        exit 0
      fi
      echo "ERROR: $SEALING_KEYS not found. Restore it from the password manager," >&2
      echo "or set ALLOW_NEW_SEALING_KEY=1 to start over with a new key." >&2
      exit 1
    fi
    # Strip server-assigned fields so the export applies to a fresh cluster.
    python3 - "$SEALING_KEYS" <<'EOF' | kubectl apply -f -
import json, sys
doc = json.load(open(sys.argv[1]))
for s in doc["items"]:
    m = s["metadata"]
    for k in ("uid", "resourceVersion", "creationTimestamp", "managedFields", "ownerReferences"):
        m.pop(k, None)
    m.get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
json.dump(doc, sys.stdout)
EOF
    ;;
  *)
    echo "usage: $0 backup|restore" >&2; exit 2 ;;
esac
