#!/bin/bash

CMD=$1;

echo ${PGPASS} > ~barman/.pgpass
if [ -f /run/secrets/pgpass ]; then
	cp /run/secrets/pgpass ~barman/.pgpass
fi
chmod 0600 ~barman/.pgpass
chown barman:barman ~barman/.pgpass

if [ "${CMD}" == "barman" ]; then
	/usr/bin/$@

else
  	rm -f /var/lib/barman/.*.lock
	for entry in $(egrep -e '^\[.*\]$' /etc/barman.d/*.conf | sed -e ' s#\[##; s#\]##; ') ; do 
		/usr/bin/barman receive-wal --drop-slot ${entry} >/dev/null 2>&1
		/usr/bin/barman receive-wal --create-slot ${entry}
		/usr/bin/barman receive-wal ${entry} &
		sleep 1
		/usr/bin/barman switch-xlog --force --archive ${entry}
 		/usr/bin/barman check ${entry}
	done
	tail -f /var/log/barman/barman.log
fi
