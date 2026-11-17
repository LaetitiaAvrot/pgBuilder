#!/bin/sh
set -e

# Drop root privileges, fixing data dir ownership first
if [ "$1" = "postgres" ] && [ "$(id -u)" = "0" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  exec gosu postgres "$0" "$@"
fi

# First start: initialize the cluster
if [ "$1" = "postgres" ] && [ ! -s "$PGDATA/PG_VERSION" ]; then
  # Superuser $PGUSER, no password, trust authentication.
  # initdb --auth=trust only writes local and loopback pg_hba entries.
  initdb \
    --username="$PGUSER" \
    --auth=trust

  echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"

  # Create $PGDATABASE using a temporary local-only server
  if [ "$PGDATABASE" != "postgres" ]; then
    pg_ctl -D "$PGDATA" -w -o "-c listen_addresses=''" start
    createdb --username="$PGUSER" "$PGDATABASE"
    pg_ctl -D "$PGDATA" -m fast -w stop
  fi
fi

exec "$@"
