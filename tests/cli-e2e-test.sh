#!/bin/bash
# End-to-end CLI test for PowerScale SmartQoS -- run ON the PowerScale node
# Quick sanity check using only `isi` CLI commands (no PAPI/REST)
set -euo pipefail

JOB_ID="99999"
JOB_PATH="/ifs/scratch/job-${JOB_ID}"
DS_NAME="slurm_qos"

echo "=== Step 0: Clean up any leftover from previous run ==="
isi performance workloads list "$DS_NAME" --format csv --no-header 2>/dev/null \
    | awk -F, '{print $1}' | while read wl; do
    [ -n "$wl" ] && echo "  removing workload $wl" && \
        isi performance workloads unpin "$DS_NAME" "$wl" 2>/dev/null || true
done
isi nfs exports list --format csv --no-header 2>/dev/null \
    | grep "$JOB_PATH" | awk -F, '{print $1}' | while read eid; do
    [ -n "$eid" ] && echo "  removing export $eid" && \
        isi nfs exports delete "$eid" --force 2>/dev/null || true
done
isi quota quotas delete "$JOB_PATH" directory --force 2>/dev/null || true
rm -rf "$JOB_PATH" 2>/dev/null || true
echo "Cleanup done."

echo ""
echo "=== Step 1: Create scratch directory ==="
mkdir -p "$JOB_PATH"
ls -ld "$JOB_PATH"

echo ""
echo "=== Step 2: Create NFS export ==="
isi nfs exports create "$JOB_PATH"
EXPORT_ID=$(isi nfs exports list --format csv --no-header | grep "$JOB_PATH" | awk -F, '{print $1}')
echo ">>> export_id = $EXPORT_ID"

echo ""
echo "=== Step 3: Create SmartQuota (100GB hard) ==="
isi quota quotas create "$JOB_PATH" directory --hard-threshold 100G --enforced true
echo ">>> quota created"

echo ""
echo "=== Step 4: Ensure SmartQoS dataset exists ==="
if ! isi performance datasets list --format csv --no-header | grep -q "$DS_NAME"; then
    echo "Creating dataset..."
    isi performance datasets create --name "$DS_NAME" export_id
else
    echo "Dataset '$DS_NAME' already exists"
fi

echo ""
echo "=== Step 5: Pin SmartQoS workload (ops=50000, bw=2000 MB/s) ==="
isi performance workloads pin "$DS_NAME" "export_id:${EXPORT_ID}" \
    --limits "protocol_ops:50000" --limits "bandwidth:2000"
WL_ID=$(isi performance workloads list "$DS_NAME" --format csv --no-header | awk -F, '{print $1}')
echo ">>> workload_id = $WL_ID"

echo ""
echo "=== Step 6: Verify ==="
echo "--- Workloads ---"
isi performance workloads list "$DS_NAME"
echo "--- NFS Exports ---"
isi nfs exports list | grep "$JOB_PATH" || echo "(none)"
echo "--- Quotas ---"
isi quota quotas list | grep "$JOB_PATH" || echo "(none)"

echo ""
echo "=========================================="
echo " PROLOG SIMULATION COMPLETE"
echo " export_id=$EXPORT_ID"
echo " workload_id=$WL_ID"
echo "=========================================="

echo ""
echo "Proceeding to EPILOG teardown..."

echo ""
echo "=== TEARDOWN ==="

echo "Step 7: Unpin workload ${WL_ID}..."
isi performance workloads unpin "$DS_NAME" "$WL_ID"

echo "Step 8: Delete quota..."
isi quota quotas delete "$JOB_PATH" directory --force

echo "Step 9: Delete NFS export ${EXPORT_ID}..."
isi nfs exports delete "$EXPORT_ID" --force

echo "Step 10: Delete directory..."
rm -rf "$JOB_PATH"

echo ""
echo "=== Step 11: Verify cleanup ==="
echo "--- Workloads ---"
isi performance workloads list "$DS_NAME"
echo "--- Exports ---"
isi nfs exports list | grep "$JOB_PATH" || echo "(none)"
echo "--- Quotas ---"
isi quota quotas list | grep "$JOB_PATH" || echo "(none)"
echo "--- Directory ---"
ls -ld "$JOB_PATH" 2>/dev/null || echo "(removed)"

echo ""
echo "=== ALL STEPS PASSED ==="
