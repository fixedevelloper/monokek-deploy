FROM minio/mc:latest AS mc

# Alpine's "mysql-client" package is actually MariaDB's client and doesn't
# ship the caching_sha2_password plugin MySQL 8 uses by default — mysqldump
# fails to auth against it. Basing on the real mysql:8 image guarantees a
# client that's always compatible with whatever MySQL version we're running.
FROM mysql:8
COPY --from=mc /usr/bin/mc /usr/bin/mc
COPY backup.sh /backup.sh
RUN chmod +x /backup.sh
ENTRYPOINT ["/backup.sh"]
