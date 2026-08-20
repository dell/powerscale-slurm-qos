#!/bin/bash
# PowerScale QoS Epilog for Slurm
# Called by slurmctld at job termination.
#
# Set PSCALE_DRY_RUN=1 to log PAPI calls without executing them.
set -euo pipefail

CONFIG="${PSCALE_QOS_CONFIG:-/etc/slurm/pscale_qos_profiles.yaml}"
STATE_DIR="/var/run/slurm/pscale"
LOG="/var/log/slurm/pscale-qos.log"
STATE_FILE="${STATE_DIR}/job-${SLURM_JOB_ID}.json"
DRY_RUN="${PSCALE_DRY_RUN:-0}"

if [[ "${DRY_RUN}" == "1" ]]; then
    log() { echo "$(date -Iseconds) EPILOG job=${SLURM_JOB_ID} $*" | tee -a "${LOG}"; }
else
    log() { echo "$(date -Iseconds) EPILOG job=${SLURM_JOB_ID} $*" >> "${LOG}"; }
fi

if [[ ! -f "${STATE_FILE}" ]]; then
    log "no state file, nothing to clean up"
    exit 0
fi

# --- Parse state + config ---
eval "$(python3 -c "
import yaml, json
cfg = yaml.safe_load(open('${CONFIG}'))
state = json.load(open('${STATE_FILE}'))
ps = cfg['powerscale']
print(f'PSCALE_HOST={ps[\"host\"]}')
print(f'PSCALE_PORT={ps[\"port\"]}')
print(f'EXPORT_ID={state.get(\"export_id\",\"\")}')
print(f'QUOTA_ID={state.get(\"quota_id\",\"\")}')
print(f'WORKLOAD_ID={state.get(\"workload_id\",\"\")}')
print(f'DATASET_ID={state.get(\"dataset_id\",\"\")}')
print(f'JOB_PATH={state[\"path\"]}')
print(f'QOS={state[\"qos\"]}')
")"

if [[ "${DRY_RUN}" != "1" ]]; then
    eval "$(python3 -c "
import yaml
cfg = yaml.safe_load(open('${CONFIG}'))
ps = cfg['powerscale']
pw_file = ps.get('password_file')
pw = open(pw_file).read().strip() if pw_file else ps.get('password', '')
ssl = '' if ps.get('verify_ssl', True) else '-k'
print(f'AUTH={ps[\"username\"]}:{pw}')
print(f'VERIFY_SSL={ssl}')
")"
    BASE_URL="https://${PSCALE_HOST}:${PSCALE_PORT}"
    CURL="curl -s ${VERIFY_SSL} -u ${AUTH}"
fi

log "Tearing down QoS=${QOS} for path=${JOB_PATH}"

# --- Step 1: Remove SmartQoS workload ---
if [[ -n "${WORKLOAD_ID}" && -n "${DATASET_ID}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
        log "[DRY RUN] Step 1: DELETE https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/performance/datasets/${DATASET_ID}/workloads/${WORKLOAD_ID}"
        log "[DRY RUN]   -> Unpin SmartQoS workload"
    else
        ${CURL} -X DELETE \
            "${BASE_URL}/platform/26/performance/datasets/${DATASET_ID}/workloads/${WORKLOAD_ID}" \
            -o /dev/null
        log "unpinned workload ${WORKLOAD_ID}"
    fi
fi

# --- Step 2: Remove SmartQuota ---
if [[ -n "${QUOTA_ID}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
        log "[DRY RUN] Step 2: DELETE https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/quota/quotas/${QUOTA_ID}"
        log "[DRY RUN]   -> Remove SmartQuota"
    else
        ${CURL} -X DELETE "${BASE_URL}/platform/26/quota/quotas/${QUOTA_ID}" -o /dev/null
        log "deleted quota ${QUOTA_ID}"
    fi
fi

# --- Step 3: Remove NFS export ---
if [[ -n "${EXPORT_ID}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
        log "[DRY RUN] Step 3: DELETE https://${PSCALE_HOST}:${PSCALE_PORT}/platform/26/protocols/nfs/exports/${EXPORT_ID}"
        log "[DRY RUN]   -> Remove NFS export"
    else
        ${CURL} -X DELETE "${BASE_URL}/platform/26/protocols/nfs/exports/${EXPORT_ID}" -o /dev/null
        log "deleted export ${EXPORT_ID}"
    fi
fi

# --- Step 4: Optionally remove job directory ---
if [[ "${DRY_RUN}" == "1" ]]; then
    log "[DRY RUN] Step 4: DELETE https://${PSCALE_HOST}:${PSCALE_PORT}/namespace${JOB_PATH}?recursive=true"
    log "[DRY RUN]   -> Remove scratch directory (optional)"
else
    # Uncomment to auto-delete scratch data after job completion:
    # ${CURL} -X DELETE "${BASE_URL}/namespace${JOB_PATH}?recursive=true" -o /dev/null
    # log "deleted directory ${JOB_PATH}"
    :
fi

# --- Cleanup state ---
rm -f "${STATE_FILE}"
log "epilog complete"
exit 0
