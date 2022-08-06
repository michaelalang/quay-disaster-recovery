# Single Point of Failure Database DR possibility

### adaption to primary postgresql database 

#### configure Databases and WAL forwarding

~~~
$ cat <<EOF | podman exec -ti postgresql runuser -u postgres -- /usr/bin/psql -U admin -d postgres
CREATE ROLE barman WITH
  LOGIN
  SUPERUSER
  INHERIT
  NOCREATEDB
  NOCREATEROLE
  REPLICATION
  ENCRYPTED PASSWORD 'SCRAM-SHA-256$4096:9zKJKbVZL2pD5hXLrbzTBw==$B3BgyeHulQ4e/QzgHki/5aylZh1eBmEF79cB9ySveZA=:phBXdcTKAlB2Kpk+Ek4605dCRFddTxdj/ON+EjDQ8x8=';

CREATE DATABASE barman
    WITH
    OWNER = barman
    ENCODING = 'UTF8'
    LC_COLLATE = 'en_US.utf8'
    LC_CTYPE = 'en_US.utf8'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1;

quit
~~~

#### adjust access configuration

~~~
$ echo "host replication all all trust" >> $(podman volume inspect postgresql --format "{{ .Mountpoint }}")/pg_hba.conf
$ podman exec -ti postgresql runuser -u postgres -- /usr/bin/psql -U admin -d template1 -c "SELECT pg_reload_conf();" 
~~~

### configure barman to pickup streaming backups from your primary postgresql database

~~~
$ cat <<EOF> barman.conf
[primary-pg.example.com]
description =  "PostgreSQL Database (streaming)"
conninfo = host=primary-pg.example.com user=barman password=barman
backup_method = postgres
backup_options = concurrent_backup
streaming_archiver = on
slot_name = barman
streaming_archiver_name = barman_receive_wal
streaming_archiver_batch_size = 50
path_prefix = "/usr/pgsql-14/bin"
EOF

$ chcon -t container_file_t barman.conf
~~~

### start up barman

~~~
$ podman run -d --replace --name barman \
    -v $(pwd)/barman.conf:/etc/barman.d/servers.conf:Z
    -v barman:/var/lib/barman/:Z 
    -v restore:/restore:Z \
     quay.chester.at/michi/barman:latest
~~~

### start an initial backup

~~~
$ podman exec -ti barman barman backup primary-pg.example.com
~~~

### recover from a previously created backup and WAL until now

~~~
$ podman exec -ti barman barman list-backups primary-pg.example.com
primary-pg.example.com 20220721T142350 - Thu Jul 21 14:23:52 2022 - Size: 90.7 MiB - WAL Size: 0 B

$ podman exec -ti barman barman recover primary-pg.example.com 20220721T142350 /restore/
Starting local restore for server primary-pg.example.com using backup 20220721T142350
Destination directory: /restore/
Copying the base backup.
Copying required WAL segments.
Generating archive status files
Identify dangerous settings in destination directory.

Recovery completed (start time: 2022-07-21 14:27:27.706109, elapsed time: 4 seconds)

Your PostgreSQL server has been successfully prepared for recovery!
~~~

### startup your DR postgresql instance

~~~
$ podman run -rm --replace --name dr-postgresql -d -e POSTGRES_USER=admin -e POSTGRES_PASSWORD=changeme -e POSTGRES_DB=template1 -p 5432:5432 -v restore:/var/lib/postgresql/data/ docker.io/library/postgres:latest
~~~

### verify functionality of your recovered postgresql instance

~~~
$ podman exec -ti dr-postgresql runuser -u postgres -- /usr/bin/psql -U admin -d template1 -c "quit"
~~~

## using the demo playbook 

the playbook creates an Postgresql instance with two databases (barman and quay). It spawns a S3 Storage and Quay instance and creates the barman WAL backup. After pushing content, it replicates the S3 Storage and starts a Barman recovery. 
Afterwards it shut's down the Postgresql and Quay instances to startup the Disaster recovery instances of it. To verify functionality it pulls the pushed content from the initial step.

- the playbook requires three community modules to be installed
    - community.postgresql
    - containers.podman
    - community.crypto

install those upfront with

~~~
$ ansible-galaxy collection install containers.podman community.postgresql community.crypto
~~~

- ensure to configure the approriate values in the vars section
    - RECOVERY_NAME, prefix for containers, volumes, ...
    - QUAY_IO_USERNAME
    - QUAY_IO_PASSWORD
- enable FIREWALL: true, if you container host is running with firewall enabled
- configure your inventory
    - Group **barman**
        - the system you intend to run the postgresql back/recovery to
        - this system needs to be colocated with the recoverydb due to local volumes assumption
    - Group **primarydb** 
        - the system you intend to run the primary postgresql instance on
    - Group **recoverydb**
        - the system you intend to run the postgresql DR instance
        - this system needs to be colocated with the barman instance due to local volumes assumption
    - Group **minio**
        - the system(s) you intend to run the S3 backend storage on
    - Group **quay**
        - the system(s) you intend to run the primary Quay and DR Quay instance on

there are two example inventories included 

- inventory-single-node, this inventory configures a single node for all instances
- inventory, this inventory configures at least two nodes for DR show casing

run the playbook like

~~~
$ ansible-playbook -e "QUAY_IO_USERNAME=myuser QUAY_IO_PASSWORD=mypassword" demo-dr.yml -i inventory-single-node 

PLAY [Barman Postgresql recovery playbook] ****************************************************************************************************************************

TASK [Gathering Facts] ************************************************************************************************************************************************
ok: [node1.example.com]

TASK [Login to default registry and create ${XDG_RUNTIME_DIR}/containers/auth.json] ***********************************************************************************
changed: [node1.example.com]

TASK [Pull container Images] ******************************************************************************************************************************************
ok: [node1.example.com] => (item=quay.io/rhn_support_milang/barman:latest)

TASK [Pull container Images] ******************************************************************************************************************************************
ok: [node1.example.com] => (item=quay.io/rhn_support_milang/barman:latest)
ok: [node1.example.com] => (item=docker.io/library/postgres:latest)

TASK [Pull container Images] ******************************************************************************************************************************************
ok: [node1.example.com] => (item=quay.io/quay/redis:latest)
ok: [node1.example.com] => (item=quay.io/projectquay/quay:v3.7.3)

TASK [Pull container Images] ******************************************************************************************************************************************
ok: [node1.example.com] => (item=docker.io/minio/minio:latest)

TASK [install required packages] **************************************************************************************************************************************
ok: [node1.example.com] => (item=python3-psycopg2)

TASK [Configure Firewall access] **************************************************************************************************************************************
skipping: [node1.example.com] => (item=5432/tcp) 

TASK [Configure Firewall access] **************************************************************************************************************************************
skipping: [node1.example.com] => (item=9000/tcp) 
skipping: [node1.example.com] => (item=9001/tcp) 

TASK [Configure Firewall access] **************************************************************************************************************************************
skipping: [node1.example.com] => (item=443/tcp) 

TASK [Create container Volumes for persistent storage] ****************************************************************************************************************
changed: [node1.example.com] => (item=quay-barman)

TASK [Create container Volumes for persistent storage] ****************************************************************************************************************
changed: [node1.example.com] => (item=quay-recoverydb)

TASK [Create container Volumes for persistent storage] ****************************************************************************************************************
changed: [node1.example.com] => (item=quay-primarydb)

TASK [Create container Volumes for persistent storage] ****************************************************************************************************************
changed: [node1.example.com] => (item=quay-quay)

TASK [Create container Volumes for persistent storage] ****************************************************************************************************************
changed: [node1.example.com] => (item=quay-minio)

TASK [create primary Postgresql] **************************************************************************************************************************************
changed: [node1.example.com]

TASK [create MinIO instances] *****************************************************************************************************************************************
changed: [node1.example.com]

TASK [get mcli for configuration of MinIO] ****************************************************************************************************************************
ok: [node1.example.com]

TASK [configure mcli aliases] *****************************************************************************************************************************************
changed: [node1.example.com] => (item={'name': 'minio1', 'uri': 'http://127.0.0.1:9000', 'access': 'minioadmin', 'secret': 'minioadmin'})
changed: [node1.example.com] => (item={'name': 'minio2', 'uri': 'http://127.0.0.1:9000', 'access': 'minioadmin', 'secret': 'minioadmin'})

TASK [configure MinIO Buckets] ****************************************************************************************************************************************
changed: [node1.example.com] => (item=minio1)
failed: [node1.example.com] (item=minio2) => {"ansible_loop_var": "item", "changed": true, "cmd": ["mcli", "mb", "minio2/quay"], "delta": "0:00:00.023467", "end": "2022-08-06 13:17:50.257789", "item": "minio2", "msg": "non-zero return code", "rc": 1, "start": "2022-08-06 13:17:50.234322", "stderr": "mcli: <ERROR> Unable to make bucket `minio2/quay`. Your previous request to create the named bucket succeeded and you already own it.", "stderr_lines": ["mcli: <ERROR> Unable to make bucket `minio2/quay`. Your previous request to create the named bucket succeeded and you already own it."], "stdout": "", "stdout_lines": []}
...ignoring

TASK [configure MinIO S3 user access] *********************************************************************************************************************************
changed: [node1.example.com] => (item=minio1)
changed: [node1.example.com] => (item=minio2)

TASK [grant users access to MinIO] ************************************************************************************************************************************
changed: [node1.example.com] => (item=minio1)
changed: [node1.example.com] => (item=minio2)

TASK [create database users] ******************************************************************************************************************************************
changed: [node1.example.com] => (item={'name': 'barman', 'password': 'changeme', 'flags': 'CREATEDB,CREATEROLE,SUPERUSER,LOGIN,INHERIT,REPLICATION'})
changed: [node1.example.com] => (item={'name': 'quay', 'password': 'changeme', 'flags': 'LOGIN'})

TASK [create Postgresql databases] ************************************************************************************************************************************
changed: [node1.example.com] => (item={'name': 'barman', 'owner': 'barman'})
changed: [node1.example.com] => (item={'name': 'quay', 'owner': 'quay'})

TASK [create database extension] **************************************************************************************************************************************
changed: [node1.example.com]

TASK [get pg_hba.conf location] ***************************************************************************************************************************************
ok: [node1.example.com]

TASK [update connection permissions of primary Postgresql] ************************************************************************************************************
changed: [node1.example.com]

TASK [reload pg_hba.conf] *********************************************************************************************************************************************
changed: [node1.example.com]

TASK [create Quay instance] *******************************************************************************************************************************************

TASK [quay : remove any existing Quay instance] ***********************************************************************************************************************
ok: [node1.example.com]

TASK [get quay config location] ***************************************************************************************************************************************
ok: [node1.example.com]

TASK [quay : create privatekey for selfsigned certificate] ************************************************************************************************************
changed: [node1.example.com]

TASK [quay : create selfsigned certificate] ***************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : sign selfsigned certificate] *****************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : create Quay-Redis instance] ******************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : create Quay config] **************************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : update permissions for Quay config] **********************************************************************************************************************
changed: [node1.example.com]

TASK [quay : create Quay instance] ************************************************************************************************************************************
changed: [node1.example.com]

TASK [wait 10 seconds for quay to initialize] *************************************************************************************************************************
Pausing for 10 seconds
(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)
ok: [node1.example.com]

TASK [get barman.conf location] ***************************************************************************************************************************************
ok: [node1.example.com]

TASK [configure barman instance] **************************************************************************************************************************************
changed: [node1.example.com]

TASK [create Barman instances] ****************************************************************************************************************************************
changed: [node1.example.com]

TASK [wait 10 seconds for barman to initialize] ***********************************************************************************************************************
Pausing for 10 seconds
(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)
ok: [node1.example.com]

TASK [create admin quay user] *****************************************************************************************************************************************
FAILED - RETRYING: create admin quay user (10 retries left).
FAILED - RETRYING: create admin quay user (9 retries left).
ok: [node1.example.com]

TASK [Login to dr registry and create ${XDG_RUNTIME_DIR}/containers/auth.json] ****************************************************************************************
changed: [node1.example.com]

TASK [tag the barman image to localhost/barman:demo] ******************************************************************************************************************
changed: [node1.example.com]

TASK [push the barman image to localhost/barman:demo] *****************************************************************************************************************
changed: [node1.example.com]

TASK [create initial Barman backup] ***********************************************************************************************************************************
changed: [node1.example.com]

TASK [get barman Backup ID] *******************************************************************************************************************************************
changed: [node1.example.com]

TASK [change permissions on /restore] *********************************************************************************************************************************
changed: [node1.example.com]

TASK [create restore from Barman] *************************************************************************************************************************************
changed: [node1.example.com]

TASK [sync MinIO buckets] *********************************************************************************************************************************************
changed: [node1.example.com]

TASK [stop primary instances] *****************************************************************************************************************************************
changed: [node1.example.com] => (item=quay-primarydb)
changed: [node1.example.com] => (item=quay-barman)
changed: [node1.example.com] => (item=quay-redis)
changed: [node1.example.com] => (item=quay-quay)

TASK [create recovery Postgresql] *************************************************************************************************************************************
changed: [node1.example.com]

TASK [create Quay instance] *******************************************************************************************************************************************

TASK [quay : remove any existing Quay instance] ***********************************************************************************************************************
ok: [node1.example.com]

TASK [get quay config location] ***************************************************************************************************************************************
ok: [node1.example.com]

TASK [quay : create privatekey for selfsigned certificate] ************************************************************************************************************
ok: [node1.example.com]

TASK [quay : create selfsigned certificate] ***************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : sign selfsigned certificate] *****************************************************************************************************************************
ok: [node1.example.com]

TASK [quay : create Quay-Redis instance] ******************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : create Quay config] **************************************************************************************************************************************
changed: [node1.example.com]

TASK [quay : update permissions for Quay config] **********************************************************************************************************************
ok: [node1.example.com]

TASK [quay : create Quay instance] ************************************************************************************************************************************
changed: [node1.example.com]

TASK [wait 10 seconds for quay to initialize] *************************************************************************************************************************
Pausing for 10 seconds
(ctrl+C then 'C' = continue early, ctrl+C then 'A' = abort)
ok: [node1.example.com]

TASK [Login to dr registry and create ${XDG_RUNTIME_DIR}/containers/auth.json] ****************************************************************************************
FAILED - RETRYING: Login to dr registry and create ${XDG_RUNTIME_DIR}/containers/auth.json (6 retries left).
FAILED - RETRYING: Login to dr registry and create ${XDG_RUNTIME_DIR}/containers/auth.json (5 retries left).
changed: [node1.example.com]

TASK [pull demo-barman image] *****************************************************************************************************************************************
ok: [node1.example.com]

PLAY RECAP ************************************************************************************************************************************************************
node1.example.com            : ok=62   changed=41   unreachable=0    failed=0    skipped=3    rescued=0    ignored=1  
~~~
