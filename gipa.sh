#!/bin/bash
# shellcheck disable=SC2003
:
# shellcheck disable=SC2015
DBG=${DBG:-0} && [ "0$DBG" -eq 0 ]; [ "$DBG" -eq 1 ] && set -x
export DBG

PATH=/bin:/usr/bin:$PATH
export PATH

PROG=$(realpath "$0" | sed 's|^.*\/||')
# shellcheck disable=SC2034,SC2064
PID=$$
SIGNALS=0
TMPFILES=""
TMPDIRS=""

if [ -t 1 ] && [ ! -p /dev/stdin ]; then
    STTY="stty $(stty -g)"
else
    STTY=":"
fi

_trap() {
    local commands="$1" && shift
    local signals="$*"

    # shellcheck disable=SC2064,SC2086
    trap "${commands}" ${signals}

    SIGNALS=$(echo "${SIGNALS} ${signals}" | sort -u | xargs echo)

    return
}

_exit() {
    # Not re-entrant
    # shellcheck disable=SC2086
    trap - ${SIGNALS}

    local err=""; [ $# -ge 1 ] && err=$1 && shift
    local errmsg=""; [ $# -ge 1 ] && errmsg="$*"

    ERRNO=${err:-$ERRNO}
    ERRMSG="${errmsg:-$ERRMSG}"
    #[ -n "${ERRNO}" -a -n "${err}" ] && ERRNO="${err}"
    #[ -n "${ERRMSG}" -a -n "${errmsg}" ] && ERRMSG="${errmsg}"

    # shellcheck disable=SC2086
    [ -n "${TMPFILES}" ] && rm -f ${TMPFILES}
    # shellcheck disable=SC2086
    [ -n "${TMPDIRS}" ] && rm -rf ${TMPDIRS}

    $STTY

    if [ "0${ERRNO}" -ne 0 ]; then
        [ -n "${ERRMSG}" ] && echo 2>&1 "${PROG}: Error - ${ERRMSG}"
        exit "$ERRNO"
    else
        exit 0
    fi
}

_trap '_exit' 0 3


#
# END OF BOILERPLATE


# FUNCTIONS
#

#
# END OF FUNCTIONS


#
#
#
ADMIN=""
FQDN=""
HOST=""
REALM=""
STDOUT=/dev/null
STDERR=/dev/null

type firefox >/dev/null 2>&1 || _exit 1 "missing firefox binary"
type waypipe >/dev/null 2>&1 || _exit 1 "missing waypipe binary"

getopt -T >/dev/null 2>&1
[ $? -ge 4 ] || _exit 2 "getopt(1) is too old!"

usage() {
	ERRNO=0; [ $# -ge 1 ] && ERRNO=$1 && shift

    echo 2>&1 "$PROG: [-v|--verbose] [-A|--admin=<IPA Administrator>] [-r|--realm=<Kerberos realm>] [-s|--server=<ipa server>]"

	_exit "$ERRNO"
}

ARGS=$(getopt --options vA:r:s: --longoptions verbose,admin:,realm:,server: --name "$PROG" -- ${1+"$@"}) || usage $?
eval "set -- $ARGS"

while true; do
	case "$1" in
	-v|--verbose)
		STDOUT=/dev/stdout
		STDERR=/dev/stderr
		shift
		;;
	-A|--admin)
		ADMIN=$2
		shift 2
		;;
	-r|--realm)
		REALM=$2
		shift 2
		;;
    -s|--server)
        HOST=$2
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

[ $# -eq 0 ] || usage 1

if [ -z "${REALM}" ]; then
        type crudini >/dev/null 2>&1 || _exit 3 "missing crudini binary"

        REALM=$(sed 's/^[\t ]*//' /etc/krb5.conf | crudini --get - "libdefaults" "default_realm")
fi

if [ -z "${HOST}" ]; then
    # pseudo random
    FQDN=$(host -t SRV "_kerberos._udp.${REALM}" | awk '
        {
            record[FNR] = $0
        }
        END {
            i = split(record[FNR], a)
            if (i > 0)
                print a[i]
        }')
else
    if echo "${HOST}" | grep -q '\.'; then
        FQDN="${HOST}"
    else
        FQDN=$(host "${HOST}" | awk '{print $1}')
    fi
fi

# Setup new credential if needed
if [ -n "${ADMIN}" ]; then
    CCNAME=$(umask 0077; mktemp --tmpdir "krb5cc_${PROG}XXX")
    TMPFILES="${TMPFILES} ${CCNAME}"
    export KRB5CCNAME="FILE:${CCNAME}"

    # Generate new ticket
    kinit -l 15m "$ADMIN"
fi
klist -s || _exit 4

MOZDIR=$(umask 0077; mktemp --directory --tmpdir ".mozilla_${PROG}XXX")
TMPDIRS="${TMPDIRS} ${MOZDIR}"

cat << %E%O%T% >"${MOZDIR}/user.js"
user_pref("browser.toolbarbuttons.introduced.sidebar-button", true);
user_pref("sidebar.verticalTabs.dragToPinPromo.dismissed", true);
%E%O%T%

firefox --new-instance --no-remote --profile "${MOZDIR}" "https://${FQDN}/ipa/ui" >"${STDOUT}" 2>"${STDERR}"

_exit $?
