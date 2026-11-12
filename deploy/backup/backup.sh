#!/bin/bash
# Runs forever: dumps both MySQL databases and mirrors the object-storage bucket on a
# fixed interval, then prunes anything older than the retention window.
# Simpler to reason about in a container than wiring up a real cron daemon.
set -euo pipefail

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
KEEP_MIN="${BACKUP_KEEP_MIN:-7}"
INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-86400}"

mkdir -p /backups/mysql /backups/minio

# --- Ownership of the backup folder ------------------------------------------------------------------------------------------
# The purge below deletes files. A folder must therefore only ever be written (and purged) by the stack whose database it holds:
# the folder remembers the MySQL server_uuid it belongs to, and a stack with another database REFUSES to touch it. (A test stack
# once pointed at a real stack's folder and its purge wiped the real history.) A folder without a marker (older versions) is adopted.
SERVER_UUID="$(mysql -h mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -N -B -e 'select @@server_uuid' 2>/dev/null || true)"
if [[ -z "${SERVER_UUID}" ]]; then
    echo "[backup] ERROR: cannot read the MySQL server identity, refusing to run"; sleep 300; exit 1
fi
OWNER_FILE=/backups/.owner
if [[ -f "${OWNER_FILE}" && "$(head -n1 "${OWNER_FILE}")" != "${SERVER_UUID}" ]]; then
    echo "[backup] ERROR: /backups belongs to ANOTHER database ($(head -n1 "${OWNER_FILE}")), this one is ${SERVER_UUID}."
    echo "[backup] ERROR: refusing to write or purge there. Give this stack its own BACKUP_DIR (the compose project name is appended)."
    sleep 300; exit 1
fi
printf '%s\n# folder owned by the MySQL server above; written by backup.sh\n' "${SERVER_UUID}" > "${OWNER_FILE}"

# rclone remote "backup" defined through the environment (no config file to ship or leak). Same variables as before:
# MINIO_ACCESS_KEY / MINIO_SECRET_KEY are simply the S3 credentials of the storage (SeaweedFS), whatever the name.
export RCLONE_CONFIG_BACKUP_TYPE=s3
export RCLONE_CONFIG_BACKUP_PROVIDER=SeaweedFS
export RCLONE_CONFIG_BACKUP_ENDPOINT="http://seaweedfs:8333"
export RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID="${MINIO_ACCESS_KEY}"
export RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY="${MINIO_SECRET_KEY}"

# Retention: delete what is older than RETENTION_DAYS, BUT never the newest KEEP_MIN of each series, whatever their age. Only this
# script's own names are considered (<db>-*.sql.gz and <YYYYMMDD-HHMMSS> snapshot folders), nothing else in the folder is touched.
is_older_than_retention() { [[ -n "$(find "$1" -maxdepth 0 -mtime "+${RETENTION_DAYS}")" ]]; }

prune() {
    local db f d
    for db in "${MONOKEK_DB_NAME}" "${PMS_DB_NAME}"; do
        while IFS= read -r f; do
            [[ -n "${f}" ]] || continue
            if is_older_than_retention "${f}"; then rm -f -- "${f}" && echo "[backup] purged ${f}"; fi
        done < <(find /backups/mysql -maxdepth 1 -type f -name "${db}-*.sql.gz" -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP_MIN + 1))" | cut -d' ' -f2-)
    done
    while IFS= read -r d; do
        [[ -n "${d}" ]] || continue
        if is_older_than_retention "${d}"; then rm -rf -- "${d}" && echo "[backup] purged ${d}"; fi
    done < <(find /backups/minio -maxdepth 1 -mindepth 1 -type d -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{6}' -printf '%T@ %p\n' | sort -rn | tail -n +"$((KEEP_MIN + 1))" | cut -d' ' -f2-)
}

run_backup() {
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    echo "[backup] Starting run ${stamp}"

    # `run_backup` is invoked as `run_backup || ...` in the loop below, which
    # disables `set -e` for everything executed inside this function (a
    # well-known bash gotcha) — a failed mysqldump piped into gzip would
    # otherwise silently produce an empty-but-valid .sql.gz and this function
    # would still report success. Check each dump's exit status explicitly.
    for db in "${MONOKEK_DB_NAME}" "${PMS_DB_NAME}"; do
        if mysqldump -h mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" \
            --single-transaction --routines --triggers "${db}" \
            | gzip > "/backups/mysql/${db}-${stamp}.sql.gz"; then
            echo "[backup] MySQL dump done: ${db}"
        else
            echo "[backup] ERROR: mysqldump failed for ${db}"
            rm -f "/backups/mysql/${db}-${stamp}.sql.gz"
            return 1
        fi
    done

    # "copy" into a dated folder: nothing is ever deleted from the bucket, each run is a full snapshot (same as the old mc mirror).
    rclone copy --quiet "backup:${MINIO_BUCKET}" "/backups/minio/${stamp}" \
        || echo "[backup] WARN: storage mirror failed, continuing"

    prune

    echo "[backup] Run ${stamp} done"
}

while true; do
    run_backup || echo "[backup] WARN: run failed, will retry next interval"
    echo "[backup] Sleeping ${INTERVAL_SECONDS}s"
    sleep "${INTERVAL_SECONDS}"
done
