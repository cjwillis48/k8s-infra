#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-blog}"
APP_LABEL="${APP_LABEL:-ghost}"
OUT_DIR="${OUT_DIR:-$(pwd)/backups}"
STAMP="$(date +%F-%H%M%S)"
OUT_FILE="${OUT_FILE:-${OUT_DIR}/blog-backup-${STAMP}.tgz}"

mkdir -p "${OUT_DIR}"

POD="$(kubectl -n "${NAMESPACE}" get pod -l "app=${APP_LABEL}" -o jsonpath='{.items[0].metadata.name}')"

if [[ -z "${POD}" ]]; then
  echo "Error: no pod found in namespace '${NAMESPACE}' with label app=${APP_LABEL}" >&2
  exit 1
fi

echo "==> Creating backup archive inside pod ${POD}"
kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c 'tar czf /tmp/blog-backup.tgz -C /var/lib/ghost/content .'

echo "==> Copying archive locally to ${OUT_FILE}"
kubectl -n "${NAMESPACE}" cp "${POD}:/tmp/blog-backup.tgz" "${OUT_FILE}"

echo "==> Cleaning temporary archive from pod"
kubectl -n "${NAMESPACE}" exec "${POD}" -- rm -f /tmp/blog-backup.tgz

echo "==> Backup complete"
ls -lh "${OUT_FILE}"
