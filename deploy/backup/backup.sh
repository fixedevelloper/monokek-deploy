#!/bin/bash
# Runs forever: dumps both MySQL databases and mirrors the object-storage bucket on a
# fixed interval, then prunes anything older than the retention window.
# Simpler to reason about in a container than wiring up a real cron daemon.
set -euo pipefail

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-86400}"

mkdir -p /backups/mysql /backups/minio

mc alias set backup-target "http://seaweedfs:8333" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" >/dev/null

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

    mc mirror --quiet "backup-target/${MINIO_BUCKET}" "/backups/minio/${stamp}" \
        || echo "[backup] WARN: storage mirror failed, continuing"

    find /backups/mysql -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
    find /backups/minio -maxdepth 1 -mindepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +

    echo "[backup] Run ${stamp} done"
}

while true; do
    run_backup || echo "[backup] WARN: run failed, will retry next interval"
    echo "[backup] Sleeping ${INTERVAL_SECONDS}s"
    sleep "${INTERVAL_SECONDS}"
done
