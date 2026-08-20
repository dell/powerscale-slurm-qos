#!/bin/bash
# End-to-end PAPI test for PowerScale SmartQoS -- run ON the PowerScale node
set -euo pipefail

PAPI="isi_papi_tool"
JOB_ID="99999"
JOB_PATH="/ifs/scratch/job-${JOB_ID}"
DS_ID=2   # slurm_qos dataset

# Helper: POST/PUT with JSON body via stdin
papi_body() {
    local method=$1 uri=$2 body=$3
    echo "$body" | $PAPI "$method" "$uri"
}

# Helper: extract JSON field from isi_papi_tool output (find the JSON object)
papi_json() {
    python3 -c "
import sys, json, re
text = sys.stdin.read()
# Find the JSON object in the output
match = re.search(r'\{.*\}', text, re.DOTALL)
if match:
    print(json.loads(match.group())['$1'])
else:
    print('ERROR: no JSON found in:', text, file=sys.stderr)
    sys.exit(1)
"
}

echo "=== Step 0: Clean up any leftover from previous run ==="
# Clean up workloads
for wl in $($PAPI GET /26/performance/datasets/${DS_ID}/workloads 2>/dev/null | python3 -c "
import sys,json,re
m=re.search(r'\{.*\}',sys.stdin.read(),re.DOTALL)
if m:
    for w in json.loads(m.group()).get('workloads',[]):
        print(w['id'])
" 2>/dev/null); do
    echo "  removing workload $wl"
    $PAPI DELETE /26/performance/datasets/${DS_ID}/workloads/$wl 2>/dev/null || true
done
# Clean up exports for job path
for eid in $(isi nfs exports list --format json --no-footer 2>/dev/null | python3 -c "
import sys,json
for line in sys.stdin:
    try:
        e=json.loads(line)
        if any('/ifs/scratch/job-' in p for p in e.get('Paths',[])):
            print(e['ID'])
    except: pass
" 2>/dev/null); do
    echo "  removing export $eid"
    isi nfs exports delete "$eid" --force 2>/dev/null || true
done
# Clean up quotas via CLI
isi quota quotas delete "$JOB_PATH" directory --force 2>/dev/null || true
rm -rf "$JOB_PATH" 2>/dev/null || true
echo "Cleanup done."

echo ""
echo "=== Step 1: Create scratch directory ==="
mkdir -p "$JOB_PATH"
ls -ld "$JOB_PATH"

echo ""
echo "=== Step 2: Create NFS export ==="
EXPORT_JSON='{"paths":["'"$JOB_PATH"'"]}'
echo "Payload: $EXPORT_JSON"
EXPORT_RESP=$(papi_body POST /26/protocols/nfs/exports "$EXPORT_JSON")
echo "$EXPORT_RESP"
EXPORT_ID=$(echo "$EXPORT_RESP" | papi_json id)
echo ">>> export_id = $EXPORT_ID"

echo ""
echo "=== Step 3: Create SmartQuota (100GB hard) ==="
QUOTA_JSON='{"path":"'"$JOB_PATH"'","type":"directory","enforced":true,"include_snapshots":false,"thresholds":{"hard":107374182400}}'
echo "Payload: $QUOTA_JSON"
QUOTA_RESP=$(papi_body POST /25/quota/quotas "$QUOTA_JSON")
echo "$QUOTA_RESP"
QUOTA_ID=$(echo "$QUOTA_RESP" | papi_json id)
echo ">>> quota_id = $QUOTA_ID"

echo ""
echo "=== Step 4: Pin SmartQoS workload ==="
echo "    ops=50000, bandwidth=2097152000 bytes/s (2000 MB/s)"
WL_JSON='{"metric_values":{"export_id":'"$EXPORT_ID"'},"limits":{"protocol_ops":50000,"bandwidth":2097152000}}'
echo "Payload: $WL_JSON"
WL_RESP=$(papi_body POST /26/performance/datasets/${DS_ID}/workloads "$WL_JSON")
echo "$WL_RESP"
WL_ID=$(echo "$WL_RESP" | papi_json id)
echo ">>> workload_id = $WL_ID"

echo ""
echo "=== Step 5: Verify -- list workloads (PAPI) ==="
$PAPI GET /26/performance/datasets/${DS_ID}/workloads

echo ""
echo "=== Step 6: Verify via CLI ==="
echo "--- Workloads ---"
isi performance workloads list slurm_qos
echo "--- NFS Exports ---"
isi nfs exports list | grep "$JOB_PATH" || echo "(none for $JOB_PATH)"
echo "--- Quotas ---"
isi quota quotas list | grep "$JOB_PATH" || echo "(none for $JOB_PATH)"

echo ""
echo "=========================================="
echo " PROLOG SIMULATION COMPLETE"
echo " export_id=$EXPORT_ID"
echo " quota_id=$QUOTA_ID"
echo " workload_id=$WL_ID"
echo "=========================================="

echo ""
echo "Proceeding to EPILOG teardown..."

echo ""
echo "=== TEARDOWN ==="

echo "Step 7: Unpin workload ${WL_ID}..."
$PAPI DELETE /26/performance/datasets/${DS_ID}/workloads/${WL_ID}

echo "Step 8: Delete quota ${QUOTA_ID}..."
isi quota quotas delete "$JOB_PATH" directory --force

echo "Step 9: Delete NFS export ${EXPORT_ID}..."
$PAPI DELETE /26/protocols/nfs/exports/${EXPORT_ID}

echo "Step 10: Delete directory..."
rm -rf "$JOB_PATH"

echo ""
echo "=== Step 11: Verify cleanup ==="
echo "--- Workloads ---"
$PAPI GET /26/performance/datasets/${DS_ID}/workloads
echo "--- Exports ---"
isi nfs exports list | grep "$JOB_PATH" || echo "(none)"
echo "--- Quotas ---"
isi quota quotas list | grep "$JOB_PATH" || echo "(none)"
echo "--- Directory ---"
ls -ld "$JOB_PATH" 2>/dev/null || echo "(removed)"

echo ""
echo "=== ALL STEPS PASSED ==="
