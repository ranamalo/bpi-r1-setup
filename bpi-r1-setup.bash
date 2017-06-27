#!/bin/bash

# pretty colors
declare -x NC='\e[0m' # No Color
declare -x Red='\e[1;31m'
declare -x Green='\e[1;32m'
declare -x Yellow='\e[1;33m'
declare -x Blue='\e[1;34m'
declare -x Magenta='\e[1;35m'
declare -x Cyan='\e[1;36m'
declare -x White='\e[1;37m'

# get script dir
current_dir=$(pwd)
script_dir=$(dirname $0)

if [ $script_dir = '.' ]
then
        script_dir="$current_dir"
fi

scriptname=$(basename $0)
interfaces_file='/etc/network/interfaces'
swconfig_file='/etc/network/if-pre-up.d/swconfig'
hostapdconf_file='/etc/hostapd/hostapd.conf'
hostapdinit_file='/etc/init.d/hostapd'
dhcpdconf_file='/etc/dhcp/dhcpd.conf'
dhcpddefault_file='/etc/default/isc-dhcp-server'
namedconf_file='/etc/bind/named.conf.options'
shorewall_dir='/etc/shorewall'
kernel_number=$(uname -r)


usage="USAGE
=====
  $scriptname [-h] -w <wpa_passphrase> -s <ssid_name>

  -h : display help
  -w : the wpa passphrase for your AP
  -s : the SSID for your AP

Example:
$scriptname -w password1 -s ssidtest

The above will configure the bpi-r1 to be a wired and wireless router with the supplied wpa passphrase and SSID
"

while getopts ":w:s:h" opt; do
    case $opt in
        w)
            wpa_passphrase="${OPTARG}"
            ;;
        s)
            ssid="${OPTARG}"
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            printf "${usage}\n"
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            exit 1
            ;;
        h)
            printf "${usage}\n"
            exit 0
            ;;
    esac
done

shift $((OPTIND-1))

if [ -z ${wpa_passphrase} ]
then
    printf "${Red}FAIL:${NC}Missing Arguments\n"
    printf "${usage}\n"
    exit 1
elif [ -z ${ssid} ]
then
    printf "${Red}FAIL:${NC}Missing Arguments\n"
    printf "${usage}\n"
    exit 1
fi

printf "${Blue}Running the interactive program bananian-config:${NC}\n"
bananian-config

printf "${Blue}Ignore the above reboot message. You will be asked to reboot at the end of configuration${NC}\n\n"

printf "${Blue}Editing the ${swconfig_file} file...${NC}\n"
if grep 'exit 0' ${swconfig_file}
then
    sed -i 's/exit 0/#exit 0/' ${swconfig_file}
else
    if not grep '#exit 0' ${swconfig_file}
    then
        printf "${Red}Fail:${NC} didn't find 'exit 0' commented or uncommented in ${swconfig_file}. Check this file manually. Perhaps there has been an update by bananian and this script needs to be also updated. Exiting...\n"
        exit 1
    fi
fi

printf "${Blue}Editing the ${interfaces_file} file...${NC}\n"
cat << EOF > ${interfaces_file}
auto lo
iface lo inet loopback

auto eth0.101
    iface eth0.101 inet dhcp

auto eth0.102
    iface eth0.102 inet manual

auto wlan0
    iface wlan0 inet manual

auto br0
    iface br0 inet static
    bridge_ports eth0.102 wlan0
    bridge_waitport 0
    address 10.0.0.1
    network 10.0.0.0
    netmask 255.255.255.0
EOF

printf "${Blue}Installing general packages...${NC}\n"
aptitude update
aptitude safe-upgrade -y
aptitude install -y unzip bzip2 libssl-dev dnsutils bridge-utils bash-completion vim lynx nmap

printf "${Blue}Installing patched wireless realtek 8192cu driver...${NC}\n"
aptitude install -y linux-headers-${kernel_number} build-essential dkms git psmisc libnl-3-dev libnl-genl-3-dev pkg-config
ln -s /usr/src/linux-headers-${kernel_number}/arch/arm /usr/src/linux-headers-${kernel_number}/arch/armv7l
dkms_8192cu_version=$(dkms status | grep '8192cu' |sed 's/://g'| awk '{ print $2}')
if [ ! -z ${dkms_8192cu_version} ]
then
    printf "dkms remove 8192cu/${dkms_8192cu_version} --all"
    dkms remove 8192cu/${dkms_8192cu_version} --all
fi

cd /root
git clone https://github.com/desflynn/realtek-8192cu-concurrent-softAP.git
cd realtek-8192cu-concurrent-softAP
cd rtl8192cu-fixes
make
make install
cd ..
dkms add ./rtl8192cu-fixes
dkms install 8192cu/1.10
depmod -a
cp ./rtl8192cu-fixes/blacklist-native-rtl8192.conf /etc/modprobe.d/
printf "${Blue}Ignore the Error on the build for arm7l, we've symlinked the build for arm to arm7l${NC}\n\n"

printf "${Blue}Installing patched hostapd package...${NC}\n"
apt-get -y remove hostapd
tar zxvf hostapd-2.4.tar.gz
cd hostapd-2.4
patch -p1 -i ../hostapd-rtl871xdrv/rtlxdrv.patch
cp ../hostapd-rtl871xdrv/driver_* src/drivers
cd hostapd
cp defconfig .config
echo CONFIG_DRIVER_RTW=y >> .config
echo CONFIG_LIBNL32=y >> .config
make
make install
cd ../..

cp /root/realtek-8192cu-concurrent-softAP/configs/hostapd /etc/default/
mkdir /etc/hostapd

cat << EOF > ${hostapdconf_file}
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
macaddr_acl=0
auth_algs=3
ignore_broadcast_ssid=0


#WPA2 settings
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP

# CHANGE THE PASSPHRASE
wpa_passphrase=${wpa_passphrase}

# Most modern wireless drivers in the kernel need driver=nl80211
#driver=nl80211
driver=rtl871xdrv
max_num_sta=8
beacon_int=100
wme_enabled=1
wpa_group_rekey=86400

# set proper interface
interface=wlan0
bridge=br0
hw_mode=g
# best channels are 1 6 11 14 (scan networks first to find which slot is free)
channel=6
# this is the network name
ssid=${ssid}
EOF

cat << "EOF" > ${hostapdinit_file}
#!/bin/sh

### BEGIN INIT INFO
# Provides:     hostapd
# Required-Start:   $remote_fs $syslog
# Required-Stop:    $remote_fs $syslog
# Should-Start:     $network
# Should-Stop:
# Default-Start:    2 3 4 5
# Default-Stop:     0 1 6
# Short-Description:    Advanced IEEE 802.11 management daemon
# Description:      Userspace IEEE 802.11 AP and IEEE 802.1X/WPA/WPA2/EAP
#           Authenticator
### END INIT INFO

PATH=/sbin:/bin:/usr/sbin:/usr/bin
DAEMON_SBIN=/usr/local/bin/hostapd
DAEMON_DEFS=/etc/default/hostapd
DAEMON_CONF=
NAME=hostapd
DESC="advanced IEEE 802.11 management"
PIDFILE=/var/run/hostapd.pid

[ -x "$DAEMON_SBIN" ] || exit 0
[ -s "$DAEMON_DEFS" ] && . /etc/default/hostapd
[ -n "$DAEMON_CONF" ] || exit 0

DAEMON_OPTS="-B -P $PIDFILE $DAEMON_OPTS $DAEMON_CONF"

. /lib/lsb/init-functions

case "$1" in
  start)
    log_daemon_msg "Starting $DESC" "$NAME"
    start-stop-daemon --start --oknodo --quiet --exec "$DAEMON_SBIN" \
        --pidfile "$PIDFILE" -- $DAEMON_OPTS >/dev/null
    log_end_msg "$?"
    ;;
  stop)
    log_daemon_msg "Stopping $DESC" "$NAME"
    start-stop-daemon --stop --oknodo --quiet --exec "$DAEMON_SBIN" \
        --pidfile "$PIDFILE"
    log_end_msg "$?"
    ;;
  reload)
    log_daemon_msg "Reloading $DESC" "$NAME"
    start-stop-daemon --stop --signal HUP --exec "$DAEMON_SBIN" \
        --pidfile "$PIDFILE"
    log_end_msg "$?"
    ;;
  restart|force-reload)
    $0 stop
    sleep 8
    $0 start
    ;;
  status)
    status_of_proc "$DAEMON_SBIN" "$NAME"
    exit $?
    ;;
  *)
    N=/etc/init.d/$NAME
    echo "Usage: $N {start|stop|restart|force-reload|reload|status}" >&2
    exit 1
    ;;
esac

exit 0
EOF
# perms
chmod 755 ${hostapdinit_file}
# startup on boot
update-rc.d hostapd defaults

printf "${Blue}Installing dhcp server...${NC}\n"
aptitude -y install isc-dhcp-server
printf "${Blue}FYI: We expect the auto start of the dhcp server to fail because the interfaces won't be setup until we reboot${NC}\n\n"
cat << "EOF" > ${dhcpdconf_file}
ddns-update-style none;

option domain-name "mncarpenters.net";
option domain-name-servers 8.8.8.8, 8.8.4.4;

default-lease-time 600;
max-lease-time 7200;

authoritative;

log-facility local7;

subnet 10.0.0.0 netmask 255.255.255.0 {
  range 10.0.0.100 10.0.0.200;
  option routers 10.0.0.1;
}
EOF

sed -i 's/INTERFACES.*/INTERFACES="br0"/g' ${dhcpddefault_file}

printf "${Blue}Installing dns server...${NC}\n"
aptitude install -y bind9

cat << "EOF" > ${namedconf_file}
acl goodclients {
    10.0.0.0/8;
    localhost;
    localnets;
};

options {
    directory "/var/cache/bind";

    recursion yes;
    allow-query { goodclients; };
    forwarders {
        205.171.3.65;
        8.8.8.8;
        8.8.4.4;
    };
    forward only;

        // If there is a firewall between you and nameservers you want
        // to talk to, you may need to fix the firewall to allow multiple
        // ports to talk.  See http://www.kb.cert.org/vuls/id/800113

        // If your ISP provided one or more IP addresses for stable
        // nameservers, you probably want to use them as forwarders.
        // Uncomment the following block, and insert the addresses replacing
        // the all-0's placeholder.

        // forwarders {
        //      0.0.0.0;
        // };

        //========================================================================
        // If BIND logs error messages about the root key being expired,
        // you will need to update your keys.  See https://www.isc.org/bind-keys
        //========================================================================
        dnssec-validation auto;

        auth-nxdomain no;    # conform to RFC1035
        listen-on-v6 { any; };
};
EOF

printf "${Blue}Installing shorewall...${NC}\n"
aptitude install -y shorewall
cat << "EOF" > ${shorewall_dir}/interfaces
# For information about entries in this file, type "man shorewall-interfaces"
###############################################################################
?FORMAT 2
###############################################################################
#ZONE   INTERFACE   OPTIONS
net     eth0.101        dhcp,tcpflags,nosmurfs,routefilter,logmartians,sourceroute=0
loc     br0             tcpflags,nosmurfs,routefilter,logmartians,routeback
EOF

cat << "EOF" > ${shorewall_dir}/masq
# For information about entries in this file, type "man shorewall-masq"
################################################################################################################
#INTERFACE:DEST     SOURCE      ADDRESS     PROTO   PORT(S) IPSEC   MARK    USER/   SWITCH  ORIGINAL
#                                           GROUP       DEST
eth0.101        10.0.0.0/8
EOF

cat << "EOF" > ${shorewall_dir}/policy
# For information about entries in this file, type "man shorewall-policy"
###############################################################################
#SOURCE     DEST        POLICY      LOG LEVEL   LIMIT:BURST

loc     net     ACCEPT
net     all     DROP        info
$FW     net     ACCEPT
# THE FOLLOWING POLICY MUST BE LAST
all     all     REJECT      info
EOF


cat << "EOF" > ${shorewall_dir}/rules
# For information about entries in this file, type "man shorewall-rules"
######################################################################################################################################################################################################
#ACTION     SOURCE      DEST        PROTO   DEST    SOURCE      ORIGINAL    RATE        USER/   MARK    CONNLIMIT   TIME        HEADERS     SWITCH      HELPER
#                           PORT    PORT(S)     DEST        LIMIT       GROUP
?SECTION ALL
?SECTION ESTABLISHED
?SECTION RELATED
?SECTION INVALID
?SECTION UNTRACKED
?SECTION NEW

#       Don't allow connection pickup from the net
#
Invalid(DROP)   net     all     tcp
#
#   Accept DNS connections from the firewall to the network
#
DNS(ACCEPT) $FW     net
#
#   Accept SSH connections from the local network for administration
#
SSH(ACCEPT) loc     $FW
# 
#   Accept SSH connections from the internet 
SSH(ACCEPT) net     $FW
#
#   Allow Ping from the local network
#
Ping(ACCEPT)    loc     $FW

#
# Drop Ping from the "bad" net zone.. and prevent your log from being flooded..
#

Ping(DROP)  net     $FW

ACCEPT      $FW     loc     icmp
ACCEPT      $FW     net     icmp
#
EOF

cat << "EOF" > ${shorewall_dir}/zones
# For information about entries in this file, type "man shorewall-zones"
###############################################################################
#ZONE   TYPE    OPTIONS         IN          OUT
#                   OPTIONS         OPTIONS
fw  firewall
net ipv4
loc ipv4
EOF

sed -i 's/IP_FORWARDING.*/IP_FORWARDING=On/g' ${shorewall_dir}/shorewall.conf
# shorewall start on boot
sed -i 's/startup=.*/startup=1/' /etc/default/shorewall

printf "${Blue}Please reboot the router${NC}\n"
