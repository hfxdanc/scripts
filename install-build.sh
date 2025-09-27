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
getPassword() {
    _PROMPT="Password:"; [ $# -ge 1 ] && _PROMPT="$*"

    _STRING=""
    _LENGTH=0

    while IFS='' read -sr -t 30 -p "$_PROMPT" -n 1 _CHAR; do
        if [ "$_CHAR" = '' ] ; then
            [ -p /dev/stdin ] || echo "" >/dev/tty
            break
        fi
        if [ "$_CHAR" = "$(printf '\177')" ] ; then
            if [ $_LENGTH -gt 0 ] ; then
                _LENGTH=$(expr "0$_LENGTH" - 1)
                _STRING=$(echo "$_STRING" | sed 's/^\(.*\).$/\1/')
                _PROMPT="$(printf '\b \b')"
            else
                _PROMPT=''
            fi
        else
            _LENGTH=$(expr "0$_LENGTH" + 1)
            _PROMPT='*'
            _STRING="${_STRING}$_CHAR"
        fi
    done

    echo "$_STRING"

    return 0
}

getVerifiedPassword () {
    _PROMPT="Password:"; [ $# -ge 1 ] && _PROMPT="$*"

    _RC=1

    _PASSWORD=$(getPassword "$_PROMPT")

    if [ -n "$_PASSWORD" ]; then
        _PASSWORD2=$(getPassword "Verifying - Password:")

        if [ "$_PASSWORD" = "$_PASSWORD2" ]; then
            echo "$_PASSWORD"
            _RC=0
        fi
    fi
    return $_RC
}

getISO () {
    local releasever=$1

    curl -L -s https://download.fedoraproject.org/pub/fedora/linux/releases/${releasever}/Everything/x86_64/iso/ | awk '
    /CHECKSUM/  {
                    if (match($0, /^.*<a href=.*>(.*)<\/a>.*$/, a) > 0) {
                        print gensub(/-CHECKSUM/, ".iso", 1, a[1])

                        exit(0)
                    } else
                        exit(1)
                }'
 
    return $?
}


#
# END OF FUNCTIONS

VERBOSE=""
DRYRUN=0
STDOUT=/dev/null
STDERR=/dev/null
OPTS=""
LOCAL_USER=""
ADMIN=""
NAME=""
FEDORA=""
KID=""
CDROM="/dev/cdrom"
PASSWORD=""
SALT=$(dd if=/dev/urandom of=/dev/stdout bs=256 count=1 status=none | tr -dc '[:alnum:]' | head -c 8) || _exit 1 "no SALT generated"
SERIAL=$(dd if=/dev/urandom of=/dev/stdout bs=256 count=1 status=none | tr -dc '[:digit:]' | head -c 5) || _exit 1 "no SERIAL2 generated"
TIMESOURCE1=""
TIMESOURCE2=""
CONNECT="--connect=qemu:///system"
OVMF=/usr/share/OVMF


if [ "$(id -ru)" = 0 ]; then
    ID=""
    SUDO=""
else
    ID=$(id -run)
    SUDO="sudo"
fi

# shellcheck disable=SC2046
eval $(klist | awk '
    /Default principal:/ {
        if (split($3, a, "@") == 2)
            printf("KID=%s\nREALM=%s\n", a[1], a[2])
    }'
)


getopt -T >/dev/null 2>&1
[ $? -ge 4 ] || _exit 1 "getopt(1) is too old!"

usage() {
    ERRNO=0; [ $# -ge 1 ] && ERRNO=$1 && shift

    echo 2>&1 "$PROG: [-v|--verbose] [-d|--dry-run] [-L|--local-user=<vm user>] [-p|--local-password=<encypted string>] -A|--admin=<AD Administrator> -n|--name=<name for vm> -f|--fedora=<fedora releasever> realm-name"

    _exit "$ERRNO"
}

ARGS=$(getopt --options vdL:p:A:n:f: --longoptions verbose,dry-run,local-user:,local-password:,admin:,name:,fedora: --name "$PROG" -- ${1+"$@"}) || usage $?
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
        DRYRUN=1
        OPTS="$OPTS --print-xml 2 --dry-run"
        shift
        ;;
    -L|--local-user)
        LOCAL_USER=$2
        shift 2
        ;;
    -p|--local-password)
        PASSWORD="$2"
        shift 2
        ;;
    -A|--admin)
        ADMIN=$2
        shift 2
        ;;
    -n|--name)
        NAME=$2
        shift 2
        ;;
    -f|--fedora)
        FEDORA=$2
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

[ -z "$NAME" ] || [ -z "$FEDORA" ] || [ -z "$ADMIN" ] && usage 1
FQDN="${NAME}.${DOMAIN}"
KICKSTART="${FQDN}-f${FEDORA}-ks.cfg"
ISO=$(getISO $FEDORA)

if [ -n "$KID" ]; then
    if [ "$ADMIN" = "$KID" ]; then
        echo "${PROG}: Warning - Kerberos ID of principal will not be added to guest wheel group" 2>$STDERR 1>&2
    elif [ "$ID" = "$KID" ]; then
        echo "${PROG}: ID \"$ID\" will be added to guest wheel group" 1>$STDOUT
    else
        echo "${PROG}: Warning - non Kerberos ID \"ID\" will not be added to guest wheel group" 2>$STDERR 1>&2
    fi
fi

if [ -n "$LOCAL_USER" ]; then
    if [ -z "$PASSWORD" ]; then
        # shellcheck disable=SC3045
        read -t 0 >/dev/null 2>&1
        [ $? -eq 1 ] || _exit 1 "read(1) does not support timeout"

        # shellcheck disable=SC3045
        read -st 0 >/dev/null 2>&1
        [ $? -eq 1 ] || _exit 1 "read(1) does not support silent"

        PASSWORD=$(getVerifiedPassword "Password for ${LOCAL_USER}:" | openssl passwd -6 -salt "$SALT" -stdin)
    fi
    if [ -n "$PASSWORD" ]; then
        LOCAL_USER="user --name $LOCAL_USER --password $PASSWORD --iscrypted --group wheel"
    else
        echo "${PROG}: Warning - password for $LOCAL_USER not verified, ignoring user" 2>$STDERR 1>&2
        LOCAL_USER=""
    fi
fi

# set-up AD
if [ $DRYRUN -ne 1 ]; then
    TMPDIR=$(mktemp --directory --tmpdir "${PROG}-XXXXXXXXXX")
    TMPDIRS="$TMPDIRS $TMPDIR"
    chmod +rx "$TMPDIR"

    TMPFILE=$(umask 0077; mktemp --tmpdir="$TMPDIR" "${PROG}-XXXXXXXXXX")
    TMPFILES="$TMPFILES $TMPFILE"
    KRB5CCNAME="FILE:$TMPFILE"
 
    # Generate new token to pass into guest
    kinit -c "$KRB5CCNAME" -l 30m "$ADMIN"

    adcli show-computer --login-ccache="$KRB5CCNAME" "$FQDN" >/dev/null 2>&1
    case $? in
    5)
	# Good - not found
        :
        ;;
    6)
        _exit 1 "Couldn't authenticate to active directory $DOMAIN"
        ;;
    *)
        _exit 1 "Computer account $NAME already exists in $DOMAIN"
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
    adcli preset-computer $VERBOSE \
        --login-ccache="$KRB5CCNAME" \
        --domain-ou="$OU" \
        --service-name=nfs \
        --one-time-password="$OTP" \
        --os-name="Fedora Linux" \
        --os-version="$FEDORA (Workstation Edition)" \
        "$FQDN" >$STDOUT 2>$STDERR || _exit 1 "Could not preset AD account for $FQDN"

    # Pass credentials into VM to finish setup
    # Don't add TMPFILE to TMFILES as virt-install will chown to qemu:qemu 
    TMPFILE=$(umask 0077; mktemp --tmpdir "${PROG}-XXXXXXXXXX" 2>$STDERR)
    mkisofs -o "$TMPFILE" "$TMPDIR" >$STDOUT 2>$STDERR || _exit 1 "Could not create ISO for credentials"
    CDROM="$TMPFILE"

fi

# build kickstart file
if systemctl is-active --quiet chronyd; then
    # shellcheck disable=SC2046
    eval $(awk '
    /^server[:space:]*/ {
        servers[$2] = 1
    }
    END {
        i = length(servers)
        for (server in servers) {
            printf("NTP%d=%s\n", i, server)
            i--
        }
    }' /etc/chrony.conf)
fi
[ -n "$NTP1" ] && TIMESOURCE1="timesource --ntp-server=$NTP1"
[ -n "$NTP2" ] && TIMESOURCE2="timesource --ntp-server=$NTP2"

# shellcheck disable=SC2046
eval $(timedatectl show --property=Timezone 2>&1) || _exit 1 "no Timezone"

# shellcheck disable=SC2154
cat <<-%E%O%T% >"$KICKSTART"
repo --name=fedora-updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f${FEDORA}&arch=x86_64
repo --name=rpmfusion-free --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=free-fedora-${FEDORA}&arch=x86_64 --includepkgs=rpmfusion-free-release --install
repo --name=rpmfusion-free-updates --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=free-fedora-updates-released-${FEDORA}&arch=x86_64 --install
repo --name=rpmfusion-nonfree --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-${FEDORA}&arch=x86_64 --includepkgs=rpmfusion-nonfree-release --install
repo --name=rpmfusion-nonfree-updates --mirrorlist=https://mirrors.rpmfusion.org/mirrorlist?repo=nonfree-fedora-updates-released-${FEDORA}&arch=x86_64 --install
repo --name=google-chrome --baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64 --install

# Use network installation
url --metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-\$releasever&arch=\$basearch

# System bootloader configuration
autopart --type=btrfs --nohome
bootloader --append="console=tty0 console=ttyS0,115200n8" --leavebootorder --location=mbr
ignoredisk --only-use=disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0-0-0-0

eula --agreed


# Firewall configuration
firewall --enabled --service=mdns,samba-client

# Network information
network --noipv6 --bootproto=dhcp --device=link --activate --hostname $FQDN

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'

# System language
lang $LANG

# System services
services --enabled=sshd,NetworkManager,ModemManager

# System timesources?
$TIMESOURCE1
$TIMESOURCE2
# System timezone
timezone $Timezone --utc

# X Window System configuration information
xconfig  --defaultdesktop=GNOME --startxonboot

# Local user?
$LOCAL_USER

# Root password
rootpw --iscrypted --lock locked

# SELinux configuration
selinux --enforcing

# Use text mode install
text

%addon com_redhat_kdump --enable --reserve-mb=auto
%end

# Post-installation Script
%post --nochroot --log=/mnt/sysimage/var/log/anaconda/domain-join.log

# Join AD
realm join \
    --verbose \
    --install=/mnt/sysimage \
    --one-time-password=$OTP \
    --client-software=sssd \
    --server-software=active-directory \
    --membership-software=adcli \
    $DOMAIN

%end

%post

#Enable GPG keys for installed repos
cat <<EOT >> /etc/yum.repos.d/google-chrome.repo
gpgkey=https://dl-ssl.google.com/linux/linux_signing_key.pub
EOT

dnf -y install google-chrome-stable chrome-remote-desktop --refresh

# Update AD if join OK
adcli testjoin --verbose
if [ \$? -eq 0 ]; then
    mkdir /tmp/mnt && mount /dev/disk/by-id/*CD-ROM_${SERIAL} /tmp/mnt
    KRB5CCNAME="FILE:/tmp/mnt/install.sh_"
    adcli update \
        --verbose \
        --login-ccache=\$KRB5CCNAME \
        --trusted-for-delegation=yes \
        --add-samba-data

    crudini --set --existing --list /etc/sssd/sssd.conf sssd services "pac, autofs"
    crudini --set --existing /etc/sssd/sssd.conf "domain/${DOMAIN}" use_fully_qualified_names False
    crudini --set /etc/sssd/sssd.conf "domain/${DOMAIN}" auto_private_groups True
    crudini --set /etc/sssd/sssd.conf "domain/${DOMAIN}" autofs_provider ad
    crudini --del /etc/sssd/sssd.conf "domain/${DOMAIN}" fallback_homedir

    # AD queries not avaiable yet for shadow-utils commands
    [ -n "$ID" ] && ed /etc/group <<EOT
/^wheel:
a
,$ID
.
-,.j
w
q
EOT

fi

semanage boolean -m --on use_nfs_home_dirs
systemctl enable autofs

%end

# Shutdown after installation
shutdown

# From liveos install
%packages
@^workstation-product-environment
@anaconda-tools
@x86-baremetal-tools
aajohan-comfortaa-fonts
anaconda
anaconda-install-env-deps
chkconfig
glibc-all-langpacks
initscripts
kernel
kernel-modules
kernel-modules-extra
-@dial-up
-@input-methods
-@standard
-device-mapper-multipath
-fcoe-utils
-gfs2-utils
-reiserfs-utils

%end

%packages
adcli
autofs
crudini
krb5-workstation
oddjob
oddjob-mkhomedir
samba-common-tools
sssd
vim-enhanced
apg
meld
firewall-config
perl
diffstat
gcc-c++
texinfo
chrpath
ccache
perl-Thread-Queue
perl-bignum
socat
python
python3-pip
xz
python3-GitPython
python3-jinja2
SDL-devel
xterm
rpcgen
mesa-libGL-devel

%end

%E%O%T%

if [ $DRYRUN -ne 1 ]; then
    # shellcheck disable=SC2086
    VOL=$($SUDO virsh $CONNECT vol-path --pool default "${FQDN}.img" 2>$STDERR)
    if [ -z "$VOL" ]; then
        # shellcheck disable=SC2086
        $SUDO virsh $CONNECT vol-create-as default "${FQDN}.img" 50G --format raw --allocation 50G >$STDOUT 2>$STDERR
        # shellcheck disable=SC2086
        VOL=$($SUDO virsh $CONNECT vol-path --pool default "${FQDN}.img" 2>$STDERR) || _exit 1 "Could not create disk volume - ${FQDN}.img"
    fi

    $SUDO sgdisk \
        --clear \
        --new 1::+100M \
        --typecode=1:ef00 \
        --change-name=1:"EFI System" \
        --partition-guid=1:'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' \
        "$VOL" >$STDOUT 2>$STDERR


    # shellcheck disable=SC2086
    LOOP=$($SUDO losetup $VERBOSE --find --show --partscan "$VOL" >$STDOUT 2>$STDERR)
    # shellcheck disable=SC2086
    $SUDO mkfs.exfat $VERBOSE "${LOOP}p1" >$STDOUT 2>$STDERR
    # shellcheck disable=SC2086
    $SUDO losetup $VERBOSE --detach "$LOOP" >$STDOUT 2>$STDERR

    [ -n "$VERBOSE" ] && $SUDO sgdisk --print "$VOL" >$STDOUT 2>$STDERR

    VOL2=$($SUDO virsh $CONNECT vol-path --pool default "yocto.img" 2>$STDERR)
    if [ -z "$VOL2" ]; then
        # shellcheck disable=SC2086
        $SUDO virsh $CONNECT vol-create-as default "yocto.img" 100G --format raw --allocation 100G >$STDOUT 2>$STDERR
        # shellcheck disable=SC2086
        VOL2=$($SUDO virsh $CONNECT vol-path --pool default "yocto.img" 2>$STDERR) || _exit 1 "Could not create disk volume - yocto.img"
    fi

else
    # Satisfy virt-install --dry-run
    VOL="${FQDN}.img,size=10"
    VOL2="yocto.img,size=10"
fi


# Do this all in a subshell to not run into sudo timeout
# shellcheck disable=SC2086
cat <<-%E%O%T% | $SUDO /bin/sh -s
    virt-install $CONNECT \
        --name "$FQDN" \
        --memory 16384 \
        --machine q35 \
        --sysinfo host \
        --vcpus 16,sockets=2,cores=4,threads=2 \
        --cpu host \
        --seclabel type=dynamic,model=selinux,relabel=yes \
        --seclabel type=dynamic,model=dac,relabel=yes \
        --features vmport.state=off \
        --location "$ISO" \
        --extra-args "inst.ks=file:/${KICKSTART} console=ttyS0,115200n8" \
        --initrd-inject "$KICKSTART" \
        --boot uefi \
        --boot hd,cdrom,network \
        --boot bootmenu.enable=on,bios.useserial=yes \
        --boot loader="${OVMF}/OVMF_CODE.fd,loader.readonly=yes,loader.type=pflash,nvram.template=${OVMF}/OVMF_VARS.fd,loader.secure=no" \
        --os-variant detect=on,require=on \
        --disk "$VOL",format=raw,target.bus=scsi \
        --disk "$VOL2",format=raw,target.bus=scsi \
        --disk "$CDROM",device=cdrom,target.bus=scsi,serial="$SERIAL",source.startupPolicy=optional \
        --network type=direct,model=virtio,mac=RANDOM,source=enp35s0f0.8,source.mode=vepa \
        --graphics none \
        --autoconsole none \
        --hvm \
        --controller type=scsi,model=virtio-scsi \
        --controller type=virtio-serial \
        --serial pty \
        --video none \
        --memballoon none \
        --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis \
        --rng model=virtio,backend.model=random,backend=/dev/urandom \
        $OPTS

    if [ $DRYRUN -ne 1 ]; then
        while virsh $CONNECT list --state-running --name 2>$STDERR | grep "$FQDN" >/dev/null 2>&1; do
           # Wait till guest stops running
           sleep 60
        done

        INSTMEDIA=\$(virsh $CONNECT domblklist "$FQDN" 2>$STDERR | awk '{if (\$2 == "-") print \$1}')
        [ -n "\$INSTMEDIA" ] && virsh $CONNECT detach-disk "$FQDN" "\$INSTMEDIA" --config >$STDOUT 2>$STDERR

        CD=\$(virsh $CONNECT domblklist "$FQDN" 2>$STDERR | awk "{if (\\\$2 == \"$CDROM\") print \\\$1}")
        [ -n "\$CD" ] && virsh $CONNECT detach-disk "$FQDN" "\$CD" --config >$STDOUT 2>$STDERR
        rm -f "$CDROM"

    fi

%E%O%T%

_exit 0

#
#
#
cat <<- %E%O%F% >/dev/null
Last metadata expiration check: 0:03:50 ago on Thu 18 May 2023 08:46:23 AM ADT (Fedora 38)
Available Environment Groups:
   Fedora Custom Operating System
   Minimal Install
   Fedora Cloud Server
   KDE Plasma Workspaces
   Xfce Desktop
   Phosh Desktop
   LXDE Desktop
   LXQt Desktop
   Cinnamon Desktop
   MATE Desktop
   Sugar Desktop Environment
   Deepin Desktop
   Budgie Desktop
   Development and Creative Workstation
   Web Server
   Infrastructure Server
   Basic Desktop
   i3 desktop
   Sway Desktop
Installed Environment Groups:
   Fedora Server Edition
   Fedora Workstation
Installed Groups:
   Container Management
   Domain Membership
   Headless Management
   LibreOffice
   GNOME Desktop Environment
   Fonts
   Hardware Support
Available Groups:
   3D Printing
   Administration Tools
   Audio Production
   Authoring and Publishing
   Budgie
   Budgie Desktop Applications
   C Development Tools and Libraries
   Cloud Infrastructure
   Cloud Management Tools
   Compiz
   D Development Tools and Libraries
   Design Suite
   Development Tools
   Editors
   Educational Software
   Electronic Lab
   Engineering and Scientific
   FreeIPA Server
   MATE Applications
   Milkymist
   Network Servers
   Neuron Modelling Simulators
   Office/Productivity
   Python Classroom
   Python Science
   Robotics
   RPM Development Tools
   Security Lab
   Sway Window Manager (supplemental packages)
   Text-based Internet
   Window Managers
   Deepin Desktop Environment
   Graphical Internet
   KDE (K Desktop Environment)
   Games and Entertainment
   Sound and Video
   System Tools
%E%O%F%
