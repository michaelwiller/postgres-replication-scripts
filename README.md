# postgres-replication-scripts
Install and replication scripts to play with natively supported replication solutions in PostgreSQL.

    
    Databases in demo
    
                          --------
              | --------> | DB02 |  Physical replication (standby)
              |           -------- 
    --------  |       
    | DB01 | -|           --------
    --------  | --------> | DB03 |  Logical replication (primary)
              |           --------
              |
              |           --------
              | --------> | DB04 |  Physical replication (standby)
                          --------
    
    

This script is intended to be used in the following way:

Create the databases from fresh. Not part of demo.
Use pg_lsclusters to display the clusters (or use ./replication ps)

Run
     
     ./replication.sh drop && ./replication.sh create 
     
## WAL Shipping (archiving)
Set up db02 as a standby for db01 with restore_command
Now demo how data is replication only when db01 switched WAL file (pg_switch_wal())

     ./replication.sh enable_shipping  
   
Log into db01 and run

     insert into table1 values (2);
   
Notice that table1 is not being populated on db02 (or db04 for that matter).
This is because we are running the WAL shipping, but only with archiving. So transactions are only applied when db01 switches to a new WAL file.

Log in to db01 again and run


     SELECT pg_switch_wal();
     
     
Now the data is available in db02 and db04.
   

## WAL Shipping (streaming)
Enable streaming replication from db01 to db02&db04
Demo how data is continuously replication.

Run

     ./replication.sh enable_streaming 

Notice how inserts on db01 is now reflected on db02 and db04 (almost) immediately.


## WAL Shipping (synchronous commit)
To set up synchronous commit db01->db02 run

     ./replication.sh enable_sync      
   
In an environment like this, it's difficult to show the difference between synchronous commit and asynchronous streaming.
One thing can be shown though:

If you shut down db02 (which is set as the synchronous commit standby), then all commits on db01 will wait for db02 to respond.

     pg_ctlcluster 14 db02 stop

Now try to insert data on db01. Notice that the commit hangs.

We can change that behaviour though. By setting both db02 and db04 as part of the synchronous commit, and only requiring one of them to respond: commit continue, even with one server down.

Run the following to change the setting on db01:

     ./replication.sh enable_sync_any
     
     
Now notice how commits continue.

## Logical replication
The final database db03 is a primary (non-standby). Here we will set up logical replication of the two tables "table1" and "table2".

Run 

     ./replication.sh enable_logical   
     
Now notice that for "table1" inserts are reflected on db03. But updates to the table are not possible. Table1 does not have a REPLICA IDENTITY, so PostgreSQL has no idea how to identify individual rows in the table.
Table2 on the other hand, has a REPLICA IDENTITY: it has a PRIMARY KEY. So for that table insert, update and delete is available.
