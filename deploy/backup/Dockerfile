# rclone replaces MinIO's "mc": MinIO withdrew every mc distribution (Docker Hub and Quay images are gone,
# dl.min.io answers "410 Gone"), so the image could no longer be built. The storage is SeaweedFS (S3 API),
# which rclone speaks natively. rclone is a single static Go binary, so it runs on the glibc base below;
# the tag is pinned (a moving "latest" is what bit us here).
FROM rclone/rclone:1.68.2 AS rclone

# Alpine's "mysql-client" package is actually MariaDB's client and doesn't
# ship the caching_sha2_password plugin MySQL 8 uses by default — mysqldump
# fails to auth against it. Basing on the real mysql:8 image guarantees a
# client that's always compatible with whatever MySQL version we're running.
FROM mysql:8
COPY --from=rclone /usr/local/bin/rclone /usr/bin/rclone
COPY backup.sh /backup.sh
RUN chmod +x /backup.sh
ENTRYPOINT ["/backup.sh"]
