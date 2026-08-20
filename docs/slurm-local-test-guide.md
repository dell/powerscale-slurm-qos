# Local Slurm Test Environment for PowerScale QoS Integration

Test the PowerScale QoS prolog/epilog lifecycle using a single-node Slurm
cluster in Docker, without needing a live PowerScale cluster.

## Setup

Prerequisites:
- Docker (tested with Docker 28.x on WSL2)
- The `powerscale-slurm-qos/` repo cloned locally

### 1. Start the Slurm container

```bash
docker pull misterfitz/slurm:base-root
docker run -d --name slurm --hostname linux --privileged \
    -v $(pwd):/opt/pscale-qos \
    misterfitz/slurm:base-root \
    bash -c '/etc/startup.sh && tail -f /dev/null'
sleep 5
docker exec slurm sinfo
```

### 2. Enable accounting (slurmdbd + MariaDB)

```bash
docker exec slurm bash -c '
dnf install -y slurm-slurmdbd mariadb-server
mysql_install_db --user=mysql
mysqld_safe --user=mysql &
sleep 3
mysql -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS '\''slurm'\''@'\''localhost'\'';
GRANT ALL ON slurm_acct_db.* TO '\''slurm'\''@'\''localhost'\'';
FLUSH PRIVILEGES;"

cat > /etc/slurm/slurmdbd.conf << EOF
AuthType=auth/munge
DbdHost=localhost
StorageHost=localhost
StorageLoc=slurm_acct_db
StorageType=accounting_storage/mysql
StorageUser=slurm
LogFile=/var/log/slurmdbd.log
PidFile=/var/run/slurmdbd.pid
SlurmUser=slurm
EOF
chmod 600 /etc/slurm/slurmdbd.conf
chown slurm: /etc/slurm/slurmdbd.conf

slurmdbd &
sleep 3

sed -i "s|AccountingStorageType=accounting_storage/none|AccountingStorageType=accounting_storage/slurmdbd|" /etc/slurm/slurm.conf
sed -i "s|JobAcctGatherType=jobacct_gather/none|JobAcctGatherType=jobacct_gather/linux|" /etc/slurm/slurm.conf

kill $(cat /var/run/slurmctld.pid) 2>/dev/null; sleep 1
rm -f /var/spool/slurmctld/clustername
slurmctld; sleep 2
sacctmgr -i add cluster cluster
'
```

### 3. Create QoS definitions

```bash
docker exec slurm bash -c '
sacctmgr -i add account root Description="Root account" Organization="test"
sacctmgr -i add user root Account=root
sacctmgr -i add qos high         Priority=10000 MaxWall=72:00:00
sacctmgr -i add qos low          Priority=100   MaxWall=24:00:00
sacctmgr -i add qos interactive  Priority=5000  MaxWall=01:00:00
sacctmgr -i modify user root set qos+=high,normal,low,interactive defaultqos=normal
'
```

### 4. Install prolog/epilog in dry-run mode

```bash
docker exec slurm bash -c '
mkdir -p /var/run/slurm/pscale /var/log/slurm
chown -R slurm: /var/run/slurm/pscale /var/log/slurm
cp /opt/pscale-qos/config/pscale_qos_profiles.yaml /opt/pscale-qos/pscale_qos_profiles.yaml
cat >> /etc/slurm/slurm.conf << EOF

PrologSlurmctld=/opt/pscale-qos/scripts/pscale-qos-prolog.sh
EpilogSlurmctld=/opt/pscale-qos/scripts/pscale-qos-epilog.sh
DebugFlags=NO_CONF_HASH
EOF

# Enable dry-run mode (logs PAPI calls without executing them)
echo "export PSCALE_DRY_RUN=1" >> /etc/profile.d/pscale-qos.sh
echo "export PSCALE_QOS_CONFIG=/opt/pscale-qos/pscale_qos_profiles.yaml" >> /etc/profile.d/pscale-qos.sh
source /etc/profile.d/pscale-qos.sh

kill $(cat /var/run/slurmctld.pid) 2>/dev/null; sleep 1
rm -f /var/spool/slurmctld/clustername
slurmctld; sleep 2
'
```

After setup, you should have:
- A running `slurm` Docker container with accounting enabled
- QoS levels `high`, `normal`, `low`, `interactive` defined
- Prolog/epilog scripts installed with `PSCALE_DRY_RUN=1` (logs only, no PAPI calls)

## Validating the Integration

### Test all QoS levels

```bash
docker exec slurm bash -c '
> /var/log/slurm/pscale-qos.log   # clear log

sbatch --qos=high        --job-name=ai-training  --wrap="sleep 2"; sleep 5
sbatch --qos=low         --job-name=batch-job    --wrap="sleep 2"; sleep 5
sbatch --qos=interactive --job-name=debug        --wrap="sleep 2"; sleep 5
sbatch                   --job-name=default-job  --wrap="sleep 2"; sleep 5

cat /var/log/slurm/pscale-qos.log
'
```

### What to look for

Each job should produce a PROLOG + EPILOG block in the log. Verify:

1. **QoS is resolved correctly** -- the `QoS profile:` line should match
   what was passed to `--qos=`:

   ```
   PROLOG job=9  QoS profile: high
   PROLOG job=10 QoS profile: low
   PROLOG job=11 QoS profile: interactive
   PROLOG job=12 QoS profile: normal
   ```

2. **Limits match the YAML config** (`pscale_qos_profiles.yaml`):

   | QoS | protocol_ops | bandwidth (MB/s) | bandwidth (bytes/s) | quota_hard |
   |-----|-------------|-------------------|---------------------|------------|
   | high | 0 (unlimited) | 0 (unlimited) | 0 | 500 GB |
   | normal | 100,000 | 5,000 | 5,242,880,000 | 100 GB |
   | interactive | 50,000 | 2,000 | 2,097,152,000 | 20 GB |
   | low | 20,000 | 1,000 | 1,048,576,000 | 50 GB |

3. **PAPI payloads are correctly formed** -- the workload pin body should be:

   ```json
   {
       "metric_values": {"export_id": <int>},
       "limits": {"protocol_ops": <int>, "bandwidth": <int_bytes_per_sec>}
   }
   ```

   For `high` QoS (unlimited), Step 4 should say `SKIPPED`.

4. **Epilog tears down in reverse order** -- workload unpin, quota delete,
   export delete, directory delete.

5. **State file lifecycle** -- prolog creates
   `/var/run/slurm/pscale/job-<id>.json`, epilog removes it. After all
   jobs complete:

   ```bash
   docker exec slurm ls /var/run/slurm/pscale/
   # -> empty (all state files cleaned up)
   ```

### Test a single job interactively

```bash
docker exec slurm bash -c '
sbatch --qos=high --job-name=test-high --wrap="echo hello; sleep 2"
sleep 5
echo "--- PROLOG/EPILOG LOG ---"
tail -30 /var/log/slurm/pscale-qos.log
echo "--- STATE FILES ---"
ls -la /var/run/slurm/pscale/
'
```

### Inspect a state file (before epilog runs)

To see the state file before it gets cleaned up, use a longer-running job:

```bash
docker exec slurm bash -c '
sbatch --qos=low --wrap="sleep 30"
sleep 3
cat /var/run/slurm/pscale/job-*.json
'
```

Expected:

```json
{
    "job_id": "13",
    "qos": "low",
    "path": "/ifs/scratch/job-13",
    "export_id": "113",
    "quota_id": "q-13",
    "workload_id": "213",
    "dataset_id": "2",
    "protocol_ops_limit": 20000,
    "bandwidth_limit_mbps": 1000,
    "timestamp": "2026-08-19T16:10:00-04:00"
}
```

## Switching to Live PowerScale

To test against a real PowerScale cluster:

1. Edit `pscale_qos_profiles.yaml` -- set the `powerscale` section:

   ```yaml
   powerscale:
     host: powerscale.example.com  # your cluster IP or hostname
     port: 8080
     user: root
     password: "your-password"
     verify_ssl: false
   ```

2. Swap the prolog/epilog in `slurm.conf`:

   ```
   PrologSlurmctld=/opt/pscale-qos/pscale-qos-prolog.sh
   EpilogSlurmctld=/opt/pscale-qos/pscale-qos-epilog.sh
   ```

3. Ensure the container can reach the PowerScale PAPI (port 8080).

4. Pre-create the SmartQoS dataset on the cluster:

   ```bash
   # Via CLI (SSH to PowerScale):
   isi performance datasets create --name slurm_qos export_id

   # Or via PAPI:
   curl -sk -u admin:password -X POST \
       https://powerscale.example.com:8080/platform/26/performance/datasets \
       -H "Content-Type: application/json" \
       -d '{"name": "slurm_qos", "metrics": ["export_id"]}'
   ```

5. Restart slurmctld and submit a test job.

## Cleanup

```bash
docker stop slurm && docker rm slurm
```
