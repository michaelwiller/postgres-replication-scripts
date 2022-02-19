#!/usr/bin/env bash
#
# This script is to be used in conjunction with a Ubuntu server with postgres-14 installed.
#
#
# Provided under MIT License
# Copyright (c) 2022 Michael Willer

PSQL_TEMP=/tmp/psql$$.sql

# DB01
DB01_NAME="db01"
DB01_PORT="5433"
DB01_CONF="/etc/postgresql/14/db01"
DB01_LOG="/var/log/postgresql/postgresql-14-db01.log"
DB01_DATA="/var/lib/postgresql/14/db01"
DB01_CONNINFO="host=localhost port=$DB01_PORT user=repuser password=repuser"

# DB02
DB02_NAME="db02"
DB02_PORT="5434"
DB02_CONF="/etc/postgresql/14/db02"
DB02_DATA="/var/lib/postgresql/14/db02"
DB02_LOG="/var/log/postgresql/postgresql-14-db02.log"

# DB03
DB03_NAME="db03"
DB03_PORT="5435"
DB03_CONF="/etc/postgresql/14/db03"
DB03_DATA="/var/lib/postgresql/14/db03"
DB03_LOG="/var/log/postgresql/postgresql-14-db03.log"

# DB04
DB04_NAME="db04"
DB04_PORT="5436"
DB04_CONF="/etc/postgresql/14/db04"
DB04_DATA="/var/lib/postgresql/14/db04"
DB04_LOG="/var/log/postgresql/postgresql-14-db04.log"

ARCHIVEDIR="/var/lib/postgresql/db_shared_wals"

MYTABLE1_DEFINITION="create table table1 (id integer);"
MYTABLE2_DEFINITION="create table table2 (id integer primary key, value text);"

# ##############
# UTILITIES
# ##############

hl(){
  echo "=========================================================================="
}
showfile(){
  hl
  echo "Content of $1"
  hl
  cat $1
}
show_and_exec(){
  hl
  echo "RUNNING: $*"
  hl
  eval $*
}
execute_psql_file(){
  cat $2
  sleep 1
  psql -p $1 -c "$2"
}
showlog(){
  cmd=tail
  [[ "$2" == "e" ]] && cmd=vi
  case $1 in
    db01)
      $cmd $DB01_LOG
      ;;
    db02)
      $cmd $DB02_LOG
      ;;
    db03)
      $cmd $DB03_LOG
      ;;
    db04)
      $cmd $DB04_LOG
      ;;
  esac
}
execute_psql(){
  echo "$1: $2"
  sleep 1
  psql -p $1 -c "$2"
}
connect_psql(){
  case $1 in
    db01) 
      port=$DB01_PORT
      ;;
    db02) 
      port=$DB02_PORT
      ;;
    db03)
      port=$DB03_PORT
      ;;
    db04)
      port=$DB04_PORT
      ;;
  esac
  psql -p $port
}
lsclusters(){
  show_and_exec pg_lsclusters
}
restart_clusters(){
  show_and_exec "sudo systemctl daemon-reload"
  show_and_exec "sudo service postgresql restart"
  show_and_exec "pg_lsclusters"
}

# #######################
# CONFIGURATION ROUTINES
# #######################

#
# Drop all clusters db01:primary, db02:standby & db03:logical replication subscriber
# pg_dropcluster doesn't delete the configuration, if changes are made in the directory.
#
drop_clusters(){
  show_and_exec pg_dropcluster --stop 14 $DB01_NAME
  show_and_exec pg_dropcluster --stop 14 $DB02_NAME
  show_and_exec pg_dropcluster --stop 14 $DB03_NAME
  show_and_exec pg_dropcluster --stop 14 $DB04_NAME
  show_and_exec "rm -rf $DB01_CONF $DB01_DATA"
  show_and_exec "rm -rf $DB02_CONF $DB02_DATA"
  show_and_exec "rm -rf $DB03_CONF $DB03_DATA"
  show_and_exec "rm -rf $DB04_CONF $DB04_DATA"
  show_and_exec "rm -rf $ARCHIVEDIR"
  restart_clusters
}
#
# create db01 and db02 clusters
#
create_cluster(){
  dbname=$1 && shift
  dbport=$1 && shift
  dbconf=$1 && shift

  show_and_exec pg_createcluster 14 $dbname
  echo "port = $dbport" > $dbconf/conf.d/00-server.conf
}
create_clusters(){

  # Create cluster and force a specific port
  create_cluster $DB01_NAME $DB01_PORT $DB01_CONF
  create_cluster $DB02_NAME $DB02_PORT $DB02_CONF
  create_cluster $DB03_NAME $DB03_PORT $DB03_CONF
  create_cluster $DB04_NAME $DB04_PORT $DB04_CONF
  show_and_exec sudo systemctl daemon-reload
  restart_clusters
}
reset_clusters(){
 drop_clusters
 create_clusters
}
#
# Enable archive_mode, set archive_command to copy WAL files to a shared directory
# Restart the servers (only way to enable archive_mode)
#
setup_archiving_on_db01(){

  # Enable archive_mode and set archive_command on db01
  f="$DB01_CONF/conf.d/01-archiving.conf"
  [ -d $ARCHIVEDIR ] || mkdir $ARCHIVEDIR
  echo "archive_command='test ! -f $ARCHIVEDIR/%f && cp %p $ARCHIVEDIR/%f'" > $f
  echo "archive_mode=on" >> $f
  showfile $f
  restart_clusters

  # Create a simple table - for illustrations in psql later
  execute_psql $DB01_PORT "$MYTABLE1_DEFINITION"
  execute_psql $DB01_PORT "$MYTABLE2_DEFINITION"
  execute_psql $DB01_PORT "insert into table1 values (1);"
  execute_psql $DB01_PORT "insert into table2 values (1,'Value 1');"
  execute_psql $DB01_PORT "\d table1"
  execute_psql $DB01_PORT "\d table2"

  # Force db01 to switch WAL file, to illustrate that archiving is happening
  execute_psql $DB01_PORT "select pg_switch_wal();"
  sleep 2
  ls $ARCHIVEDIR
}
# Set up cluster as standby for db01. Currently db02 is a primary database, i.e. writeable.
# We need standby db to be a copy of db01.
setup_db_as_standby(){
  primary_dbport=$1 && shift
  standby_dbname=$1 && shift
  standby_dbdata=$1 && shift
  standby_dbconf=$1 && shift

  # Stop the cluster
  show_and_exec "pg_ctlcluster 14 $standby_dbname stop"

  # Remove all files
  show_and_exec "rm -rf $standby_dbdata"

  # pg_basebackup of primary port to standby directory
  show_and_exec "pg_basebackup -D $standby_dbdata -p $primary_dbport"

  # Enable standby_mode
  show_and_exec "touch $standby_dbdata/standby.signal"

  # Setup recovery (restore_command)
  f=$standby_dbconf/conf.d/01-standby-restore.conf
  echo "restore_command = 'cp $ARCHIVEDIR/%f %p'" > $f
  showfile $f
}

# Enable shipping:
# - set up archiving on db01 cluster
# - set up db02 and db04 to read and apply archived logs from db01
enable_shipping(){
  setup_archiving_on_db01
  setup_db_as_standby $DB01_PORT $DB02_NAME $DB02_DATA $DB02_CONF
  setup_db_as_standby $DB01_PORT $DB04_NAME $DB04_DATA $DB04_CONF

  # Restart the clusters (changing archive_mode requires a restart)
  restart_clusters
}

# On the standby database set up streaming client (primary_conninfo and primary_slot_name)
# Note that this is NOT a Production-ready example
# (you should use a more secure connection, like certificates or at least .pgpass)
setup_db_streaming(){
  dbname=$1 && shift
  dbconf=$1 && shift

  f="$dbconf/conf.d/02-streaming-replication-connect.conf"
  echo "# For Production systems, use more secure connection" > $f
  echo "primary_conninfo = '$DB01_CONNINFO'" >> $f
  echo "primary_slot_name = '${dbname}_streaming'" >> $f
  showfile $f
}

# Enable streaming replication
enable_streaming(){

  # Create REPLICATION user on db01
  execute_psql $DB01_PORT "create role repuser with replication password 'repuser' login;"

 # Create replication slots on db01
  execute_psql $DB01_PORT "SELECT * FROM pg_create_physical_replication_slot('${DB02_NAME}_streaming');"
  execute_psql $DB01_PORT "SELECT * FROM pg_create_physical_replication_slot('${DB04_NAME}_streaming');"

  # Default pg_hba.conf already allows replication connections from everywhere
  # But, that requires the cluster to LISTEN for connections
  f="$DB01_CONF/conf.d/02-streaming-replication-allow-connect.conf"
  echo "listen_addresses = '*'" > $f
  showfile $f

  setup_db_streaming $DB02_NAME $DB02_CONF
  setup_db_streaming $DB04_NAME $DB04_CONF

  # Restart clusters (changing listen_addresses on db01 requires restart, db02 pg_reload_conf() would be enough)
  restart_clusters
}
set_cluster_name(){
  cluster_name=$1 && shift
  dbconf=$1 && shift
  f="$dbconf/conf.d/03-synchronous-commit-application-name.conf"
  echo "cluster_name = '$cluster_name'" > $f
  showfile $f
}
set_synch_names(){
  # Use the newly set cluster_name from db02 to define synchronous standbys.
  f="$DB01_CONF/conf.d/03-synchronous-commit.conf"
  echo "synchronous_standby_names = '$1'" > $f
  showfile $f
}
# Enable synchronous commit
enable_sync(){

  # cluster_name gets important, when you want to set synchronous_standby_names
  # until that point it was purely an informational value. Now it needs to be unique.
  set_cluster_name ${DB02_NAME}_standby $DB02_CONF
  set_cluster_name ${DB04_NAME}_standby $DB04_CONF
  set_synch_names "${DB02_NAME}_standby"

  # Restart clusters (cluster_name requires restart of db02, db01 would be fine with just pg_reload_conf())
  restart_clusters
}
enable_sync_any(){

  set_synch_names "ANY 1 (${DB02_NAME}_standby, ${DB04_NAME}_standby)"
  # Restart clusters (cluster_name requires restart of db02, db01 would be fine with just pg_reload_conf())
  restart_clusters
}

# Enable Logical replication
# To illustrate logical replication we use cluster db03. 
# This is *not* a standby cluster but a fully writeable cluster.
enable_logical(){

  # Set a password for postgres user on db01, so we can use it to connect
  execute_psql $DB01_PORT "ALTER USER postgres PASSWORD 'postgres';"

  # Change wal_level to 'logical' on db01
  f="$DB01_CONF/conf.d/04-logical-replication.conf"
  echo "wal_level = 'logical'" > $f
  showfile $f

  # Restart all clusters (change of 'wal_level' requires restart, db02 and db03 don't need it - but I'm lazy)
  restart_clusters

  # Create publication. 
  # Note that publications default to publish: insert, update. delete, truncate.
  execute_psql $DB01_PORT "CREATE PUBLICATION two_tables FOR TABLE table1,table2;"

  # Create subscription.
  # Note: there are A LOT of options for subscriptions, synchronous logical just to name one (see CREATE SUBSCRIPTION for details).
  execute_psql $DB03_PORT "$MYTABLE1_DEFINITION"
  execute_psql $DB03_PORT "$MYTABLE2_DEFINITION"
  execute_psql $DB03_PORT "CREATE SUBSCRIPTION two_table_sub CONNECTION 'host=localhost port=$DB01_PORT user=postgres password=postgres dbname=postgres' PUBLICATION two_tables;"
}

help(){
  cat <<EOF
$0 action

ACTIONS:
--------------------------------------------------------------------------
drop             Drop db01 & db02 clusters
create           Create db01 & db02 clusters
reset            Drop and create
elog  dbname     Open the log for dbname in vi
log   dbname     Tail log for dbname 
ls               List clusters
ps  dbname       List database processes (ps -ef | grep 14/dbname)
use              List use cases for commands below
enable_shipping  Setup db01 for wal archiving, db02 as standby with restore
enable_streaming Setup db02 to stream WAL from db01
enable_sync      Setup synchronous commit between db01 and db02
enable_logical   Setup new server db03 and enable logical replication.
EOF
}
usecase(){
cat <<EOF
This script is intended to be used in the following way:

$0 drop && $0 create 
   Create the databases from fresh. Not part of demo.
   Use pg_lsclusters to display the clusters.

$0 enable_shipping  
   To set up db02 as a standby for db01 with restore_command
   Now demo how data is replication only when db01 switched WAL file (pg_switch_wal())

$0 enable_streaming 
   To enable streaming replication from db01 to db02&db04
   Demo how data is continuously replication.

$0 enable_sync      
   To set up synchronous commit db01->db02 & db01->db04
   Demo how shutting down db02 will hang commits on db01.

$0 enable_sync_any
   Change synchronous_standby_name to enable commit with one standby down
   Demo how commits can be done with one standby down. 

$0 enable_logical   
   Creates the final database db03 (read/write) and sets up logical replication from db01 to db03
   Demo replication of 'table1' to db03.
   Show that db03 is a read/write (i.e. primary) database.

Several commands are available for easy access to different parts of the configuration. See $0 help
EOF
}

case $1 in
  drop)
    drop_clusters
    ;;
  create)
    create_clusters
    ;;
  reset)
    reset_clusters
    enable_shipping
    enable_streaming
    enable_sync
    enable_sync_any
    enable_logical
    ;;
  elog)
    showlog $2 e
    ;;
  log)
    showlog $2 t
    ;;
  ls)
    lsclusters
    ;;
  psql)
    [ -z $2 ] && echo "I need to know which server to connect to ... db01, db02,.." && exit 0
    connect_psql $2
    ;;
  ps)
    show_and_exec "ps -ef | grep 14/$2"
    ;;
  enable_*)
    eval $1
    ;;
  use)
    usecase
    ;;
  *)
    help
    ;;
esac
[ -f $PSQL_TEMP ] && rm $PSQL_TEMP
