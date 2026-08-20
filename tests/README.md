# Tests

Test scripts for the PowerScale Slurm QoS integration. Both run on a
PowerScale node and exercise the full prolog/epilog lifecycle (create,
verify, teardown).

| Script | Interface | Best for |
|--------|-----------|----------|
| `papi-e2e-test.sh` | `isi_papi_tool` (REST payloads) | Validating PAPI payload format, catching schema issues |
| `cli-e2e-test.sh` | `isi` CLI | Quick sanity checks, simpler to read and modify |

## papi-e2e-test.sh

End-to-end test using `isi_papi_tool` (local PAPI client). Tests the exact
JSON payloads that the production prolog/epilog scripts send via curl:

1. Clean up any leftover resources from previous runs
2. Create scratch directory (`/ifs/scratch/job-99999`)
3. Create NFS export (PAPI `POST /26/protocols/nfs/exports`)
4. Create SmartQuota with 100GB hard limit (PAPI `POST /25/quota/quotas`)
5. Pin SmartQoS workload -- ops=50000, bandwidth=2000 MB/s (PAPI `POST /26/performance/datasets/<id>/workloads`)
6. Verify all resources via PAPI and CLI
7. Tear down: unpin workload, delete quota, delete export, remove directory
8. Verify cleanup -- zero workloads, no exports, no quotas, directory removed

### Usage

```bash
# Copy to PowerScale node and run
scp tests/papi-e2e-test.sh root@<powerscale-ip>:/tmp/
ssh root@<powerscale-ip> 'bash /tmp/papi-e2e-test.sh'
```

### Prerequisites

- SSH access to a PowerScale node (runs `isi_papi_tool` and `isi` CLI locally)
- OneFS 9.15+ (for bandwidth limits) or 9.5+ (protocol ops only)
- The `slurm_qos` SmartQoS dataset must already exist (dataset id=2 is hardcoded):
  ```bash
  isi performance datasets create --name slurm_qos export_id
  ```

### Validated

Tested on a PowerScale cluster running **OneFS 9.15.0.0**.

### Key findings from testing

| Finding | Detail |
|---------|--------|
| `isi_papi_tool` JSON body | Reads from **stdin**, not CLI argument |
| Quota `include_snapshots` | Required field in `POST /25/quota/quotas` |
| Quota delete | Easier via CLI (`isi quota quotas delete <path> directory --force`) than PAPI with base64 quota ID |
| `metric_values` format | Flat dict `{"export_id": N}`, not array |
| `bandwidth` units | **bytes/s** in PAPI (MB/s * 1048576), **MB/s** in CLI |

## cli-e2e-test.sh

Same lifecycle as the PAPI test but using only `isi` CLI commands. No JSON
payloads, no `isi_papi_tool` -- just straightforward OneFS CLI calls:

1. Clean up leftover resources
2. `mkdir -p /ifs/scratch/job-99999`
3. `isi nfs exports create`
4. `isi quota quotas create` (100GB hard)
5. `isi performance workloads pin` (ops=50000, bw=2000 MB/s)
6. Verify via `isi` list commands
7. Tear down: `unpin`, `delete quota`, `delete export`, `rm -rf`
8. Verify cleanup

### Usage

```bash
scp tests/cli-e2e-test.sh root@<powerscale-ip>:/tmp/
ssh root@<powerscale-ip> 'bash /tmp/cli-e2e-test.sh'
```

### Prerequisites

- SSH access to a PowerScale node
- OneFS 9.15+ (for bandwidth limits) or 9.5+ (protocol ops only)
- Dataset auto-created if missing (no hardcoded dataset ID)

### Key differences from PAPI version

| | PAPI test | CLI test |
|--|-----------|----------|
| Dataset ID | Hardcoded (`DS_ID=2`) | Looked up by name |
| Bandwidth units | bytes/s (`2097152000`) | MB/s (`2000`) |
| Quota create | Requires `include_snapshots` | Handled automatically |
| Quota delete | Base64 encoded ID | By path + type |
| Catches payload bugs | Yes | No |

## Dry-Run Testing (Docker)

For testing without a live PowerScale cluster, set `PSCALE_DRY_RUN=1` and use
the prolog/epilog scripts in a Dockerized Slurm environment. See:

- [docs/slurm-local-test-guide.md](../docs/slurm-local-test-guide.md) for the full workflow
