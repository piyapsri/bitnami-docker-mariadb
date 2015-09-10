# MariaDB Utility functions
PROGRAM_OPTIONS="--defaults-file=$BITNAMI_APP_DIR/my.cnf --log-error=$BITNAMI_APP_DIR/logs/mysqld.log --basedir=$BITNAMI_APP_DIR --datadir=$BITNAMI_APP_DIR/data --plugin-dir=$BITNAMI_APP_DIR/lib/plugin --user=$BITNAMI_APP_USER --socket=$BITNAMI_APP_DIR/tmp/mysql.sock --lower-case-table-names=1"

case "$REPLICATION_MODE" in
  master )
    PROGRAM_OPTIONS+=" --server-id=${SERVER_ID:-$RANDOM} --binlog-format=ROW --log-bin=mysql-bin --innodb_flush_log_at_trx_commit=1 --sync-binlog=1"
    ;;
  slave)
    PROGRAM_OPTIONS+=" --server-id=${SERVER_ID:-$RANDOM} --binlog-format=ROW --log-bin=mysql-bin --relay-log=mysql-relay-bin --log-slave-updates=1 --read-only=1 ${MARIADB_DATABASE:+--replicate-do-db=$MARIADB_DATABASE}"
    ;;
esac

initialize_database() {
    echo "==> Initializing MySQL database..."
    echo ""
    $BITNAMI_APP_DIR/scripts/mysql_install_db --port=3306 --socket=$BITNAMI_APP_DIR/tmp/mysql.sock --basedir=$BITNAMI_APP_DIR --datadir=$BITNAMI_APP_DIR/data > /dev/null
    chown -R $BITNAMI_APP_USER:$BITNAMI_APP_USER $BITNAMI_APP_DIR/data
}

create_custom_database() {
  if [ "$MARIADB_DATABASE" ]; then
    echo "==> Creating database $MARIADB_DATABASE..."
    echo ""
    echo "CREATE DATABASE IF NOT EXISTS \`$MARIADB_DATABASE\`;" >> /tmp/init_mysql.sql
  fi
}

create_mysql_user() {
  if [ ! "$MARIADB_USER" ]; then
    MARIADB_USER=root
  fi

  if [ "$MARIADB_USER" != "root" ] && [ ! $MARIADB_DATABASE ]; then
    echo "In order to use a custom MARIADB_USER you need to provide the MARIADB_DATABASE as well"
    echo ""
    exit -1
  fi

  echo "==> Creating user $MARIADB_USER..."
  echo ""

  echo "DELETE FROM mysql.user ;" >> /tmp/init_mysql.sql
  echo "CREATE USER '${MARIADB_USER}'@'%' IDENTIFIED BY '${MARIADB_PASSWORD}' ;" >> /tmp/init_mysql.sql

  if [ "$MARIADB_USER" = root ]; then
    echo "==> Creating root user with unrestricted access..."
    echo "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;" >> /tmp/init_mysql.sql
  else
    echo "==> Granting access to $MARIADB_USER to the database $MARIADB_DATABASE..."
    echo ""
    echo "GRANT ALL ON \`${MARIADB_DATABASE}\`.* TO \`${MARIADB_USER}\`@'%' ;" >> /tmp/init_mysql.sql
    echo "GRANT RELOAD, REPLICATION CLIENT ON *.* TO \`${MARIADB_USER}\`@'%' ;" >> /tmp/init_mysql.sql
  fi

  echo "FLUSH PRIVILEGES ;" >> /tmp/init_mysql.sql
  echo "DROP DATABASE IF EXISTS test ; " >> /tmp/init_mysql.sql
}

configure_replication() {
  case "$REPLICATION_MODE" in
    master)
      if [ "$REPLICATION_USER" ]; then
        echo "==> Creating replication user $REPLICATION_USER..."
        echo ""

        echo "GRANT REPLICATION SLAVE ON *.* TO '$REPLICATION_USER'@'%' IDENTIFIED BY '$REPLICATION_PASSWORD';" >> /tmp/init_mysql.sql
        echo "FLUSH PRIVILEGES ;" >> /tmp/init_mysql.sql
      fi
      ;;
    slave)
      echo "==> Setting up MariaDB slave..."

      echo "==> Trying to fetch MariaDB master connection parameters from the mariadb-master link..."
      MASTER_HOST=${MASTER_HOST:-$MARIADB_MASTER_PORT_3306_TCP_ADDR}
      MASTER_USER=${MASTER_USER:-$MARIADB_MASTER_ENV_MARIADB_USER}
      MASTER_PASSWORD=${MASTER_PASSWORD:-$MARIADB_MASTER_ENV_MARIADB_PASSWORD}
      REPLICATION_USER=${REPLICATION_USER:-$MARIADB_MASTER_ENV_REPLICATION_USER}
      REPLICATION_PASSWORD=${REPLICATION_PASSWORD:-$MARIADB_MASTER_ENV_REPLICATION_PASSWORD}

      echo "==> Setting the master configuration..."
      echo "CHANGE MASTER TO MASTER_HOST='$MASTER_HOST', MASTER_USER='$REPLICATION_USER', MASTER_PASSWORD='$REPLICATION_PASSWORD';" >> /tmp/init_mysql.sql

      echo "==> Checking if replication master is ready to accept connection (60s timeout)..."
      timeout=60
      while ! mysqladmin -u$MASTER_USER ${MASTER_PASSWORD:+-p$MASTER_PASSWORD} -h $MASTER_HOST status >/dev/null 2>&1
      do
        timeout=$(expr $timeout - 1)
        if [[ $timeout -eq 0 ]]; then
          echo "Could not connect to replication master"
          echo ""
          exit -1
        fi
        sleep 1
      done
      echo

      echo "==> Creating a data snapshot..."
      mysqldump -u$MASTER_USER ${MASTER_PASSWORD:+-p$MASTER_PASSWORD} -h $MASTER_HOST \
        --databases $MARIADB_DATABASE --skip-lock-tables --single-transaction --flush-logs --hex-blob --master-data --apply-slave-statements --comments=false | tr -d '\012' | sed -e 's/;/;\n/g' >> /tmp/init_mysql.sql
      echo ""
      ;;
  esac
}

print_mysql_password() {
  if [ -z $MARIADB_PASSWORD ]; then
    echo "**none**"
  else
    echo $MARIADB_PASSWORD
  fi
}

print_mysql_database() {
 if [ $MARIADB_DATABASE ]; then
  echo "Database: $MARIADB_DATABASE"
 fi
}
