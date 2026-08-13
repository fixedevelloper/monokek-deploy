#!/bin/bash
# Runs once, only when the mysql data volume is empty (official mysql image
# behavior for docker-entrypoint-initdb.d). Creates the two app databases and
# their own scoped users — monokek-spring and pms-modulith each only ever see
# their own schema, never each other's or MySQL's system tables.
set -euo pipefail

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS \`${MONOKEK_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE DATABASE IF NOT EXISTS \`${PMS_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

    CREATE USER IF NOT EXISTS '${MONOKEK_DB_USERNAME}'@'%' IDENTIFIED BY '${MONOKEK_DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${MONOKEK_DB_NAME}\`.* TO '${MONOKEK_DB_USERNAME}'@'%';

    CREATE USER IF NOT EXISTS '${PMS_DB_USERNAME}'@'%' IDENTIFIED BY '${PMS_DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${PMS_DB_NAME}\`.* TO '${PMS_DB_USERNAME}'@'%';

    FLUSH PRIVILEGES;
EOSQL
