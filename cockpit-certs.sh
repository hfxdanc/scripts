#!/bin/sh
#
DBG=${DBG:-0} && [ "0$DBG" -eq 0 ]; [ "$DBG" -eq 1 ] && set -x
export DBG

PATH=/bin:/usr/bin
export PATH

if [ "$(id -ru)" = 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

HOSTNAME=${HOSTNAME:-$(hostname -f)}

$SUDO certbot certificates --cert-name $HOSTNAME 2>/dev/null | awk '
	BEGIN {
		rc = 1
	}
       	/Certificate Name: / {
		if (split($0, a, ":") == 2) rc = 0
	}
	END {
		exit rc
	}'

if [ $? -eq 0 ]; then
	$SUDO certbot renew --cert-name $HOSTNAME

	CERT=$($SUDO /usr/libexec/cockpit-certificate-ensure --check | sed 's|^[^/]*\(/.*$\)|\1|')
	KEY=$(echo $CERT | sed 's/\.crt$/.key/')

	$SUDO cat /etc/letsencrypt/live/$HOSTNAME/fullchain.pem | $SUDO tee $CERT >/dev/null
	$SUDO cat /etc/letsencrypt/live/$HOSTNAME/privkey.pem | $SUDO tee $KEY >/dev/null

	$SUDO systemctl stop '*cockpit*'
	$SUDO systemctl start cockpit.socket
else
	echo 2>&1 "no certificate found for $HOSTNAME"
fi	

