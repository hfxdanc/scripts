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
ACCOUNT=""
ADMIN=""
DRYRUN=""
HOSTNAME=""
IPADDR=""
NAME=""
OPTS=""
STDOUT=/dev/null
STDERR=/dev/null
VERBOSE=""

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

	echo 2>&1 "$PROG: [-v|--verbose] [-d|--dry-run] [-i|--ip=<addr>] [l|--login=<remote account>] -A|--admin=<AD Administrator> -h|--hostname=<target host> realm-name"

	_exit "$ERRNO"
}

ARGS=$(getopt --options vdi:l:A:h: --longoptions verbose,dry-run,ip:,login:,admin:,hostname: --name "$PROG" -- ${1+"$@"}) || usage $?
eval "set -- $ARGS"

while true; do
	case "$1" in
	-v|--verbose)
		VERBOSE=" --verbose"
		STDOUT=/dev/stdout
		STDERR=/dev/stderr
		OPTS=" $OPTS --debug"
		shift
		;;
	-d|--dry-run)
		DRYRUN="echo"
		shift
		;;
	-i|--ip)
		IPADDR=$2
		shift 2
		;;
	-l|--login)
		ACCOUNT=$2
		shift 2
		;;
	-A|--admin)
		ADMIN=$2
		shift 2
		;;
	-h|--hostname)
		HOSTNAME=$2
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

[ $# -eq 1 ] || usage 1
DOMAIN="$1"

if [ -n "$REALM" ]; then
	if [ "$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')" != "$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')" ]; then
		echo "${PROG}: Warning - Kerberos REALM of principal does not match supplied domain argument" 2>$STDERR 1>&2
	fi
fi

[ -z "$HOSTNAME" ] || [ -z "$ADMIN" ] && usage 1
FQDN=$(echo "${HOSTNAME}.${DOMAIN}" | tr '[:upper:]' '[:lower:]')
NAME=$(echo "$FQDN" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')

# set-up AD
TMPFILE=$(umask 0077; mktemp --tmpdir "krb5cc_${PROG}XXX")
TMPFILES="$TMPFILES $TMPFILE"
KRB5CCNAME="FILE:$TMPFILE"

# Generate new token to pass into target
kinit -c "$KRB5CCNAME" -l 5m "$ADMIN"

adcli show-computer --login-ccache="$KRB5CCNAME" "$FQDN" >/dev/null 2>&1
case $? in
5)
# Good - not found
	:
	;;
6)
	$DRYRUN _exit 1 "Couldn't authenticate to active directory $DOMAIN"
	;;
*)
	$DRYRUN _exit 1 "Computer account $NAME already exists in $DOMAIN"
	;;
esac

# shellcheck disable=SC2046
eval $(awk -v domain="$DOMAIN" '
	BEGIN {
		ou = "OU=Computers,OU=Unix"
		split(domain, a, ".")
	for (i in a)
			ou=sprintf("%s,DC=%s", ou, a[i])

		printf("OU=%s\n", ou)
		exit
	}' </dev/null
)

OTP=$(dd if=/dev/urandom of=/dev/stdout bs=512 count=1 status=none | tr -dc '[:alnum:]' | head -c 32) || _exit 1 "no OTP generated"

# shellcheck disable=SC2086
$DRYRUN adcli preset-computer $VERBOSE \
	--login-ccache="$KRB5CCNAME" \
	--domain-ou="$OU" \
	--service-name=nfs \
	--one-time-password="$OTP" \
	"$FQDN" >$STDOUT 2>$STDERR || _exit 1 "Could not preset AD account for $FQDN"

# Finish setup on target
COMMANDS=$(cat <<- %E%O%T%
	PATH=/bin:/usr/bin:/usr/sbin
	export PATH

	DOMAIN=\$(hostname -d)
	FQDN=\$(hostname -f)
	TMPFILE=\$(mktemp --tmpdir krb5cc_XXXXXXXX)
	RC=0

	trap "rm -f \$TMPFILE" EXIT

	[ "\$FQDN" = "$FQDN" ] || RC=1

	if [ -z "\$SSH_ASKPASS" ]; then
		rpm -q --quiet openssh-askpass || RC=2
	fi

	if [ \$RC -eq 0 ]; then
		cat <<- %e%o%t% | base64 --decode >\$TMPFILE
			$(base64 "$TMPFILE")
		%e%o%t%

		SUDO_ASKPASS=\${SSH_ASKPASS:-"/usr/libexec/openssh/gnome-ssh-askpass"}
		export SUDO_ASKPASS

		# Install required packages
		rpm -q --quiet adcli || $SUDO dnf -y install adcli
		rpm -q --quiet crudini || $SUDO dnf -y install crudini
		rpm -q --quiet oddjob || $SUDO dnf -y install oddjob
		rpm -q --quiet oddjob-mkhomedir || $SUDO dnf -y install oddjob-mkhomedir

		rpm -q --quiet adcli crudini || RC=3
	fi

	if [ \$RC -eq 0 ]; then
		eval \$(cat /etc/os-release 2>/dev/null)
		[ -n "\$NAME" ] && OPTS="--os-name=\"\$NAME\""
		[ -n "\$VERSION" ] && OPTS="\$OPTS --os-version=\"\$VERSION\""

		# Join AD
		$SUDO realm join $VERBOSE \
			--one-time-password=$OTP \
			--client-software=sssd \
			--server-software=active-directory \
			--membership-software=adcli \
			$DOMAIN

		# Update AD if join OK
		$SUDO adcli testjoin $VERBOSE || RC=4
	fi

	if [ \$RC -eq 0 ]; then
		$SUDO adcli update $VERBOSE \$OPTS \
			--login-ccache="FILE:\${TMPFILE}" \
			--trusted-for-delegation=yes \
			--add-samba-data

		[ \$? -eq 0 ] || RC=5
	fi

	if [ \$RC -eq 0 ]; then
		$SUDO crudini --set --existing /etc/sssd/sssd.conf sssd services "nss, pam, pac, autofs" || RC=10
		$SUDO crudini --set /etc/sssd/sssd.conf "domain/\${DOMAIN}" fallback_homedir "/home/%u@%d" || RC=\$(expr \$RC + 1)
		$SUDO crudini --set /etc/sssd/sssd.conf "domain/\${DOMAIN}" use_fully_qualified_names "False" || RC=\$(expr \$RC + 1)
		$SUDO crudini --set /etc/sssd/sssd.conf "domain/\${DOMAIN}" ldap_id_mapping "False" || RC=\$(expr \$RC + 1)
		$SUDO crudini --set /etc/sssd/sssd.conf "domain/\${DOMAIN}" auto_private_groups "False" || RC=\$(expr \$RC + 1)
		$SUDO crudini --set /etc/sssd/sssd.conf "domain/\${DOMAIN}" autofs_provider "ad" || RC=\$(expr \$RC + 1)

	fi

	if [ \$RC -eq 0 ]; then
		$SUDO semanage boolean -m --on use_nfs_home_dirs || RC=6
		$SUDO systemctl enable autofs || RC=7
	fi

	exit \$RC
%E%O%T%
)

if [ "$DBG" -eq 0 ]; then
	echo "$COMMANDS" | $DRYRUN ssh -X "${ACCOUNT:-$ID}"@"${IPADDR-:$HOSTNAME}" '/bin/sh -'
elif [ "$DBG" -eq 2 ]; then
	echo "$COMMANDS" | ssh "${ACCOUNT:-$ID}"@"${IPADDR-:$HOSTNAME}" '/bin/cat - >/tmp/join.sh'
	ssh -X "${ACCOUNT:-$ID}"@"${IPADDR-:$HOSTNAME}"
else
	# shellcheck disable=SC3037
	echo -e "set -x\n$COMMANDS" | ssh -X "${ACCOUNT:-$ID}"@"${IPADDR-:$HOSTNAME}" '/bin/sh -'
fi
RC=$?

case $RC in
0)
	_exit $RC "Success! - Target \"$FQDN\" needs to be rebooted to apply changes"
	;;
1)
	_exit $RC "FQDN on target does not match pre-created AD account"
	;;
2)
	_exit $RC "openssh-askpass (or equivalent) package must be pre-installed on target"
	;;
3)
	_exit $RC "failed to install neccesary packages on target"
	;;
4)
	_exit $RC "failed to join target to Active Directory"
	;;
5)
	_exit $RC "failed to update Active Directory for target"
	;;
6)
	_exit $RC "failed to enable selinux bool \"use_nfs_home_dirs\" on target"
	;;
7)
	_exit $RC "failed to enable autofs on target"
	;;
1[0-9])
	_exit $RC "failed to adjust \"sssd.conf\" correctly on target"
	;;
*)
	_exit 0
	;;
esac
