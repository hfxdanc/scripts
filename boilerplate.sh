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


# FUNCTIONS
#

#
# END OF FUNCTIONS


