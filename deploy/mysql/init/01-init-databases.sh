#!/bin/bash
# Runs once, only when the mysql data volume is empty (official mysql image
# behavior for docker-entrypoint-initdb.d). Creates the app databases and
# their own scoped users — monokek-spring, pms-modulith and monokek-identity
# each only ever see the schema(s) they need, never each other's or MySQL's
# system tables.
set -euo pipefail

mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS \`${MONOKEK_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
    CREATE DATABASE IF NOT EXISTS \`${PMS_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

    CREATE USER IF NOT EXISTS '${MONOKEK_DB_USERNAME}'@'%' IDENTIFIED BY '${MONOKEK_DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${MONOKEK_DB_NAME}\`.* TO '${MONOKEK_DB_USERNAME}'@'%';

    CREATE USER IF NOT EXISTS '${PMS_DB_USERNAME}'@'%' IDENTIFIED BY '${PMS_DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${PMS_DB_NAME}\`.* TO '${PMS_DB_USERNAME}'@'%';

    -- monokek-identity: same schema as monokek-spring (see the extraction plan —
    -- the users/roles/permissions/user_roles/user_permissions tables stay physically
    -- where the FKs from devices/orders/cash_sessions/etc. already point, only the
    -- owning *process* changed), but its own user.
    --
    -- Originally scoped to table-level DML on just those five tables, relying on
    -- MySQL allowing GRANT on a not-yet-existing table. That assumption broke on
    -- MySQL 8.4 (mysql:8 now resolves to 8.4.x): GRANT ... ON db.not_yet_created_table
    -- now raises ERROR 1146 "table doesn't exist", which — under this script's
    -- set -e — aborted the whole init before the schema-wide CREATE/ALTER grant
    -- below ever ran, leaving identity_app with no privileges at all (just USAGE)
    -- and monokek-identity permanently unable to connect. Granted schema-wide
    -- instead: still isolated from ${PMS_DB_NAME} (identity_app has no grants there
    -- at all), just no longer restricted to five specific tables within
    -- ${MONOKEK_DB_NAME}.
    CREATE USER IF NOT EXISTS '${IDENTITY_DB_USERNAME}'@'%' IDENTIFIED BY '${IDENTITY_DB_PASSWORD}';
    GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, REFERENCES ON \`${MONOKEK_DB_NAME}\`.* TO '${IDENTITY_DB_USERNAME}'@'%';

    FLUSH PRIVILEGES;
EOSQL
