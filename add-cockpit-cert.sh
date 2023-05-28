#!/bin/sh
# shellcheck disable=SC2003
:
# shellcheck disable=SC2015
DBG=${DBG:-0} && [ "0$DBG" -eq 0 ]; [ "$DBG" -eq 1 ] && set -x
export DBG

PATH=/bin:/usr/bin:$PATH
export PATH

PROG=$(realpath "$0" | sed 's|^.*\/||')
# shellcheck disable=SC2034
PID=$$
TMPFILES=""
TMPDIRS=""

if [ -t 1 ] && [ ! -p /dev/stdin ]; then
	STTY="stty $(stty -g)"
else
	STTY=":"
fi

_trap() {
	_CMDS="$1" && shift
	_SIGNALS="$*"

	# _CMDS needs global
	# _SIGSPEC should strip redundant SIGS

	# shellcheck disable=SC2064,SC2086
	trap "$_CMDS" $_SIGNALS

	SIGSPECS="$SIGSPECS $_SIGNALS"

	return
}

_exit() {
	# Not re-entrant
	# shellcheck disable=SC2086
	trap - ${SIGSPECS:-0}

	_ERRNO=0; [ $# -ge 1 ] && _ERRNO=$1 && shift
	_ERRMSG=""; [ $# -ge 1 ] && _ERRMSG="$*"

	# shellcheck disable=SC2086
	[ -n "$TMPFILES" ] && rm -f $TMPFILES
	# shellcheck disable=SC2086
	[ -n "$TMPDIRS" ] && rm -rf $TMPDIRS

	$STTY

	if [ "0$_ERRNO" -ne 0 ]; then
		[ -n "$_ERRMSG" ] && echo 2>&1 "${PROG}: Error - $_ERRMSG"
		exit "$_ERRNO"
	else
		exit 0
	fi
}

_trap '_exit' 0 3


#
# END OF BOILERPLATE

#
#
#
DEBUG=""
MAIL=""
OPTS=""
TARGET=""
VERBOSE=""

[ "$DBG" -eq 0 ] || DEBUG="-x"

if [ "$(id -ru)" = 0 ]; then
	ID=""
	SUDO=""
else
	ID=$(id -run)
	SUDO="sudo"
fi

getopt -T >/dev/null 2>&1
[ $? -ge 4 ] || _exit 1 "getopt(1) is too old!"

usage() {
	ERRNO=0; [ $# -ge 1 ] && ERRNO=$1 && shift

	echo 2>&1 "$PROG: [-v|--verbose] [-d|--dry-run] [l|--login=<remote account>] [-m|--mail=<email address>] -h|--hostname=<target host>"

	_exit "$ERRNO"
}

ARGS=$(getopt --options vdl:m:h: --longoptions verbose,dry-run,login:,mail:,hostname: --name "$PROG" -- ${1+"$@"}) || usage $?
eval "set -- $ARGS"

while true; do
	case "$1" in
	-v|--verbose)
		VERBOSE=" --verbose"
		shift
		;;
	-d|--dry-run)
		OPTS=" --test-cert --dry-run"
		shift
		;;
	-h|--hostname)
		TARGET=$2
		shift 2
		;;
	-l|--login)
		ACCOUNT=$2
		shift 2
		;;
	-m|--mail)
		MAIL=$2
		shift 2
		;;
	--)  
		shift
		break
		;;
	*)
		usage
		;;
	esac
done

# shellcheck disable=SC2166
[ $# -eq 0 -a -n "$TARGET" ] || usage 1

if [ "$(id -ru)" = 0 ]; then
	SUDO=""
else
	SUDO="sudo"
fi

AWS_SHARED_CREDENTIAL_FILE=${AWS_SHARED_CREDENTIAL_FILE:-"$HOME/.aws/credentials"}
export AWS_SHARED_CREDENTIAL_FILE

# Transfer (all pipes) AWS credentials
# shellcheck disable=SC2029
cat << %E%O%T% | ssh "${ACCOUNT:-$ID}"@"${TARGET}" "/bin/sh $DEBUG -"
[ -d "\$HOME/.aws" ] || mkdir -m 700 "\$HOME/.aws"
%E%O%T%

# shellcheck disable=SC2181
[ $? -eq 0 ] || _exit 1 "could not create AWS credentials directory on target"

awk '
BEGIN {
	cmd=sprintf("crudini --get %s certbot aws_access_key_id\n", ENVIRON["AWS_SHARED_CREDENTIAL_FILE"])
	cmd | getline key_id

	cmd=sprintf("crudini --get %s certbot aws_secret_access_key\n", ENVIRON["AWS_SHARED_CREDENTIAL_FILE"])
	cmd | getline key

	printf("[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n", key_id, key)

	exit
}' | ssh "${ACCOUNT:-$ID}"@"${TARGET}" '/bin/cat - >.aws/certbot'

# shellcheck disable=SC2181
[ $? -eq 0 ] || _exit 1 "could not create AWS credential file on target"

DOMAIN=$(hostname -d)

LDAPBASE=$(awk -v domain="$DOMAIN" 'BEGIN {
		if (split(domain, a, ".") > 0) {
			for (i = 1; i < length(a); i++)
				printf("DC=%s,", a[i])

			printf("DC=%s\n", a[i])
		}
		exit
	}'
)

LDAPHOST=$(dig "_ldap._tcp.dc._msdcs.${DOMAIN}" SRV +short | awk '
	END {
			printf("ldap://%s\n", $4)
	}'
)

if [ -z "$MAIL" ]; then
	MAIL=$(ldapsearch \
		-LLL \
		-b "CN=users,${LDAPBASE}" \
		-s one \
		-H "$LDAPHOST" \
		-Y GSSAPI \
		"(&(objectClass=user)(sAMAccountName=${USER}))" mail 2>/dev/null | awk '
			/^mail:/ {
						print gensub(/^mail:[[:space:]]+/, "", 1)
			}'
	)
fi

[ -n "$MAIL" ] || _exit 1 "no email address for certbot. Use --mail=<email address> option"

# Finish setup on target
COMMANDS=$(cat <<- %E%O%T%
	PATH=/bin:/usr/bin:/usr/sbin
	export PATH

	trap "rm -rf \$HOME/.aws/certbot" EXIT SIGINT

	FQDN=\$(hostname -f)
	RC=0

	if [ -z "\$SSH_ASKPASS" ]; then
		rpm -q --quiet openssh-askpass || RC=1
	fi

	if [ \$RC -eq 0 ]; then
		SUDO_ASKPASS=\${SSH_ASKPASS:-"/usr/libexec/openssh/gnome-ssh-askpass"}
		export SUDO_ASKPASS

		# Install required packages
		rpm -q --quiet certbot || $SUDO dnf -y install certbot
		rpm -q --quiet python3-certbot-dns-route53 || $SUDO dnf -y install python3-certbot-dns-route53

		rpm -q --quiet certbot python3-certbot-dns-route53 || RC=2
	fi

	if [ \$RC -eq 0 ]; then
		#initialize directory structure
		$SUDO certbot certificates

		cat <<- %e%o%t% | $SUDO tee /etc/letsencrypt/renewal-hooks/deploy/cockpit.sh >/dev/null
			#!/bin/sh
			#
			PATH=/bin:/usr/bin
			export PATH

			[ "\\\$(id -ru)" -eq 0 ] || exit

			systemctl is-enabled --quiet cockpit.socket || exit
			DOMAIN=\\\$(/usr/libexec/cockpit-certificate-ensure --check | sed 's|^.*/\([^/]*\)\.ce\?rt\\\$|\1|')
			for domain in \\\$RENEWED_DOMAINS; do
				if [ "\\\$domain" = "\\\$DOMAIN" ]; then
					CERT=\\\$(/usr/libexec/cockpit-certificate-ensure --check | sed 's|^[^/]*\(/.*\\\$\)|\1|')
					KEY=\\\$(echo \$CERT | sed 's/\.ce\?rt\\\$/.key/')

					cat \\\$RENEWED_LINEAGE/fullchain.pem > \\\$CERT
					cat \\\$RENEWED_LINEAGE/privkey.pem > \\\$KEY 

					systemctl stop '*cockpit*'
					systemctl start cockpit.socket

					break
				fi
			done

			exit
%e%o%t%
	
		$SUDO chmod 755 /etc/letsencrypt/renewal-hooks/deploy/cockpit.sh

		echo '[ -d /root/.aws ] || mkdir -m 700 /root/.aws' | $SUDO /bin/sh -
		echo '[ -e /root/.aws/credentials ] && mv /root/.aws/credentials /root/.aws/credentials.SAV' | $SUDO /bin/sh -

		cat \$HOME/.aws/certbot | $SUDO tee /root/.aws/credentials >/dev/null

		$SUDO certbot certonly $VERBOSE $OPTS \
			--non-interactive \
			--domain "\$FQDN" \
			--dns-route53 \
			--agree-tos \
			--email "$MAIL"

		[ \$? -eq 0 ] || RC=3  
	fi

	if [ \$RC -eq 0 ]; then
		RENEWED_DOMAINS="\$FQDN"
		RENEWED_LINEAGE="/etc/letsencrypt/live/\$FQDN"
		export RENEWED_DOMAINS RENEWED_LINEAGE

		$SUDO /bin/sh $DEBUG /etc/letsencrypt/renewal-hooks/deploy/cockpit.sh

		[ \$? -eq 0 ] || RC=4  
	fi

	exit \$RC
%E%O%T%
)

echo "$COMMANDS" | ssh -X "${ACCOUNT:-$ID}"@"${TARGET}" "/bin/sh $DEBUG -"
RC=$?

case $RC in
0)
	_exit $RC "Success!"
	;;
1)
	_exit $RC "openssh-askpass (or equivalent) package must be pre-installed on target"
	;;
2)
	_exit $RC "failed to install neccesary packages on target"
	;;
3)
	_exit $RC "failed to obtain LetsEncypt certificate"
	;;
4)
	_exit $RC "failed to install certificate for cockpit"
	;;
*)
	_exit 0
	;;
esac
