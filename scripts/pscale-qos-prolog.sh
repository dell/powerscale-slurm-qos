#!/bin/bash
# PowerScale QoS Prolog for Slurm
# Called by slurmctld at job allocation time.
# Available env vars: SLURM_JOB_ID, SLURM_JOB_USER, SLURM_JOB_ACCOUNT,
#                     SLURM_JOB_PARTITION (note: SLURM_JOB_QOS is NOT set
#                     in PrologSlurmctld -- we query it via scontrol)
#
# Set PSCALE_DRY_RUN=1 to log PAPI calls without executing them.
set -euo pipefail

CONFIG="${PSCALE_QOS_CONFIG:-/etc/slurm/pscale_qos_profiles.yaml}"
STATE_DIR="/var/run/slurm/pscale"
LOG="/var/log/slurm/pscale-qos.log"
DRY_RUN="${PSCALE_DRY_RUN:-0}"

mkdir -p "${STATE_DIR}" "$(dirname "${LOG}")"

if [[ "${DRY_RUN}" == "1" ]]; then
    log() { echo "$(date -Iseconds) PROLOG job=${SLURM_JOB_ID} $*" | tee -a "${LOG}"; }
else
    log() { echo "$(date -Iseconds) PROLOG job=${SLURM_JOB_ID} $*" >> "${LOG}"; }
fi

# --- Parse config (requires python3 + PyYAML) ---
PSCALE_HOST=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print(cfg['powerscale']['host'])
")
PSCALE_PORT=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print(cfg['powerscale']['port'])
")

if [[ "${DRY_RUN}" != "1" ]]; then
    PSCALE_USER=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print(cfg['powerscale']['username'])
")
    PSCALE_PASS=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
pw_file = cfg['powerscale'].get('password_file')
if pw_file:
    print(open(pw_file).read().strip())
else:
    print(cfg['powerscale'].get('password', ''))
")
    VERIFY_SSL=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print('' if cfg['powerscale'].get('verify_ssl', True) else '-k')
")
    BASE_URL="https://${PSCALE_HOST}:${PSCALE_PORT}"
    AUTH="${PSCALE_USER}:${PSCALE_PASS}"
    CURL="curl -s ${VERIFY_SSL} -u ${AUTH}"
fi

# --- Resolve QoS profile ---
# SLURM_JOB_QOS is not set in PrologSlurmctld env; query scontrol
QOS_NAME=$(scontrol show job "${SLURM_JOB_ID}" 2>/dev/null \
    | grep -oP 'QOS=\K\S+' || echo "normal")
read -r PROTOCOL_OPS_LIMIT BW_LIMIT_MBPS QUOTA_HARD_GB QUOTA_SOFT_GB <<< $(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
profiles = cfg.get('profiles', {})
p = profiles.get('${QOS_NAME}', profiles.get('_default', {}))
hard = p.get('quota_hard_limit_gb', cfg.get('quota', {}).get('default_hard_limit_gb', 100))
soft = p.get('quota_soft_limit_gb', 0)
ops = p.get('protocol_ops_limit', 0)
bw = p.get('bandwidth_limit_mbps', 0)
print(f'{ops} {bw} {hard} {soft}')
")

DATASET_NAME=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print(cfg.get('dataset_name', 'slurm_qos'))
")
SCRATCH_BASE=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
print(cfg.get('scratch_base', '/ifs/scratch'))
")

JOB_PATH="${SCRATCH_BASE}/job-${SLURM_JOB_ID}"
BW_BYTES=$((BW_LIMIT_MBPS * 1048576))
QUOTA_HARD_BYTES=$((QUOTA_HARD_GB * 1073741824))

log "qos=${QOS_NAME} ops_limit=${PROTOCOL_OPS_LIMIT} bw_limit=${BW_LIMIT_MBPS}MB/s quota=${QUOTA_HARD_GB}GB path=${JOB_PATH}"

if [[ "${DRY_RUN}" == "1" ]]; then
    # --- Dry-run: log what would happen ---
    EXPORT_ID=$((SLURM_JOB_ID + 100))

    log "[DRY RUN] Step 1: PUT https://${PSCALE_HOST}:${PSCALE_PORT}/namespace${JOB_PATH}"
    log "[DRY RUN]   -> Create directory ${JOB_PATH}"

    log "[DRY RUN] Step 2: POST https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/protocols/nfs/exports"
    log "[DRY RUN]   -> Body: {\"paths\": [\"${JOB_PATH}\"]}"
    log "[DRY RUN]   -> Would return export_id: ${EXPORT_ID}"

    log "[DRY RUN] Step 3: POST https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/quota/quotas"
    log "[DRY RUN]   -> Body: {\"path\": \"${JOB_PATH}\", \"type\": \"directory\", \"enforced\": true, \"thresholds\": {\"hard\": ${QUOTA_HARD_BYTES}}}"

    LIMITS_JSON=$(python3 -c "
import json
limits = {}
if ${PROTOCOL_OPS_LIMIT} > 0:
    limits['protocol_ops'] = ${PROTOCOL_OPS_LIMIT}
if ${BW_LIMIT_MBPS} > 0:
    limits['bandwidth'] = ${BW_LIMIT_MBPS} * 1048576
print(json.dumps(limits))
")
    if [[ "${LIMITS_JSON}" != "{}" ]]; then
        log "[DRY RUN] Step 4: POST https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/performance/datasets/<ds_id>/workloads"
        log "[DRY RUN]   -> Body: {\"metric_values\": {\"export_id\": ${EXPORT_ID}}, \"limits\": ${LIMITS_JSON}}"
    else
        log "[DRY RUN] Step 4: SKIPPED (no limits to apply -- unlimited QoS)"
    fi

    WORKLOAD_ID=$((SLURM_JOB_ID + 200))
    QUOTA_ID="q-${SLURM_JOB_ID}"
    DS_ID="2"
else
    # --- Live: call PowerScale PAPI ---

    # Step 1: Create per-job directory
    ${CURL} -X PUT "${BASE_URL}/namespace${JOB_PATH}" \
        -H "x-isi-ifs-target-type: container" \
        -H "x-isi-ifs-access-control: 0755" \
        -o /dev/null -w "%{http_code}" | read HTTP_CODE
    log "mkdir ${JOB_PATH} -> ${HTTP_CODE:-done}"

    # Step 2: Create NFS export
    EXPORT_ID=$(${CURL} -X POST "${BASE_URL}/platform/26/protocols/nfs/exports" \
        -H "Content-Type: application/json" \
        -d "{\"paths\":[\"${JOB_PATH}\"]}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
    log "nfs_export id=${EXPORT_ID}"

    # Step 3: Create SmartQuota
    QUOTA_SOFT_BYTES=$((QUOTA_SOFT_GB * 1073741824))
    QUOTA_BODY="{
        \"path\": \"${JOB_PATH}\",
        \"type\": \"directory\",
        \"include_snapshots\": false,
        \"enforced\": true,
        \"thresholds\": {
            \"hard\": ${QUOTA_HARD_BYTES}
        }
    }"
    if [[ ${QUOTA_SOFT_GB} -gt 0 ]]; then
        QUOTA_BODY=$(echo "${QUOTA_BODY}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['thresholds']['advisory'] = ${QUOTA_SOFT_BYTES}
json.dump(d, sys.stdout)
")
    fi
    QUOTA_ID=$(${CURL} -X POST "${BASE_URL}/platform/26/quota/quotas" \
        -H "Content-Type: application/json" \
        -d "${QUOTA_BODY}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
    log "quota id=${QUOTA_ID} hard=${QUOTA_HARD_GB}GB"

    # Step 4: Pin SmartQoS workload (if any limit > 0)
    WORKLOAD_ID=""
    DS_ID=""
    if [[ ${PROTOCOL_OPS_LIMIT} -gt 0 || ${BW_LIMIT_MBPS} -gt 0 ]]; then
        DS_ID=$(${CURL} -X GET "${BASE_URL}/platform/26/performance/datasets" \
            | python3 -c "
import sys, json
for d in json.load(sys.stdin).get('datasets', []):
    if d.get('name') == '${DATASET_NAME}':
        print(d['id']); break
")
        if [[ -n "${DS_ID}" ]]; then
            LIMITS_JSON=$(python3 -c "
import json
limits = {}
if ${PROTOCOL_OPS_LIMIT} > 0:
    limits['protocol_ops'] = ${PROTOCOL_OPS_LIMIT}
if ${BW_LIMIT_MBPS} > 0:
    limits['bandwidth'] = ${BW_LIMIT_MBPS} * 1048576
print(json.dumps(limits))
")
            WORKLOAD_ID=$(${CURL} -X POST \
                "${BASE_URL}/platform/26/performance/datasets/${DS_ID}/workloads" \
                -H "Content-Type: application/json" \
                -d "{
                    \"metric_values\": {\"export_id\": ${EXPORT_ID}},
                    \"limits\": ${LIMITS_JSON}
                }" \
                | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
            log "smartqos workload_id=${WORKLOAD_ID} ops=${PROTOCOL_OPS_LIMIT} bw=${BW_LIMIT_MBPS}MB/s"
        else
            log "WARNING: dataset '${DATASET_NAME}' not found, skipping QoS"
        fi
    fi
fi

# --- Save state for epilog ---
cat > "${STATE_DIR}/job-${SLURM_JOB_ID}.json" <<EOF
{
    "job_id": "${SLURM_JOB_ID}",
    "qos": "${QOS_NAME}",
    "path": "${JOB_PATH}",
    "export_id": "${EXPORT_ID}",
    "quota_id": "${QUOTA_ID}",
    "workload_id": "${WORKLOAD_ID}",
    "dataset_id": "${DS_ID:-}",
    "protocol_ops_limit": ${PROTOCOL_OPS_LIMIT},
    "bandwidth_limit_mbps": ${BW_LIMIT_MBPS},
    "timestamp": "$(date -Iseconds)"
}
EOF

log "prolog complete"
exit 0
