cat << 'EOF' > setup-isolated-jail.sh
#!/bin/sh

# ==========================================
# CONFIGURATION VARIABLES
# ==========================================
WIFI_DEVICE="radio0"
WIFI_SSID="projectorwifi"
WIFI_KEY="password"
WIFI_DISABLED="1"             # Set to '0' to enable Wi-Fi immediately

SPACEDESK_IP="192.168.your.pc.ip"
SPACEDESK_PORT="28252"

JAIL_IP="192.168.99.1"
JAIL_SUBNET="192.168.99.0/24"

PROJECTOR_IP="192.168.99.108" # Your Projector's IP Address

# ==========================================

# ---------------------------------------------------------
# Strictly Isolated Zero-Trust IoT Jail & AdGuard Home
# Compatible with OpenWrt 25.x (fw4/nftables & apk)
# Zero modifications to global LAN or DNSmasq configs
# Assumes this is a downstream AP (i.e., does not do DHCP)
# ---------------------------------------------------------

echo "1. Installing AdGuard Home & dnsmasq-full..."
# dnsmasq-full is required for fw4 dynamic nftset support
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add adguardhome dnsmasq-full
else
    opkg update
    opkg remove dnsmasq
    opkg install adguardhome dnsmasq-full
fi

/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start

echo "2. Creating isolated 'jail' network & DHCP server..."
uci set network.jail=interface
uci set network.jail.proto='static'
uci set network.jail.ipaddr="${JAIL_IP}"
uci set network.jail.netmask='255.255.255.0'

uci set dhcp.jail=dhcp
uci set dhcp.jail.interface='jail'
uci set dhcp.jail.start='100'
uci set dhcp.jail.limit='150'
uci set dhcp.jail.leasetime='12h'

echo "3. Creating the Zero-Trust Firewall Zone..."
uci set firewall.jail=zone
uci set firewall.jail.name='jail'
uci set firewall.jail.input='REJECT'
uci set firewall.jail.output='ACCEPT'
uci set firewall.jail.forward='REJECT'
# Disable default zone logging to stop the DPT=1900 broadcast spam
uci set firewall.jail.log='0' 
uci -q delete firewall.jail.network
uci add_list firewall.jail.network='jail'

echo "4. Creating targeted Masquerades ONLY for the jail..."
# 4a. Outbound: Masquerade traffic leaving the jail (Fixes Spacedesk hang)
uci -q delete firewall.jail_nat

# In fw4 'config nat', 'src' is the EGRESS interface.
# This masquerades traffic leaving the 'lan' interface, but ONLY if it comes from the jail.
uci set firewall.jail_nat=nat
uci set firewall.jail_nat.name='Masquerade-Jail-Out'
uci set firewall.jail_nat.src='lan'
uci set firewall.jail_nat.src_ip="${JAIL_SUBNET}"
uci set firewall.jail_nat.proto='all'
uci set firewall.jail_nat.target='MASQUERADE'

# 4b. Inbound: Masquerade traffic entering the jail (Bypasses Android 13 subnet block for ADB/Web)
uci -q delete firewall.jail_masq
# uci set firewall.jail_masq=nat
# uci set firewall.jail_masq.name='Masquerade-LAN-In'
# uci set firewall.jail_masq.src='jail'
# uci set firewall.jail_masq.target='MASQUERADE'

echo "5. Forcing Jail DNS into AdGuard (Targeted Intercept)..."
uci -q delete firewall.jail_dns_intercept
uci set firewall.jail_dns_intercept=redirect
uci set firewall.jail_dns_intercept.name='Intercept-Jail-DNS'
uci set firewall.jail_dns_intercept.src='jail'
uci set firewall.jail_dns_intercept.src_dport='53'
uci set firewall.jail_dns_intercept.dest='jail'
uci set firewall.jail_dns_intercept.dest_port='5353'
uci set firewall.jail_dns_intercept.proto='tcp udp'

echo "6. Creating dynamic Domain Allowlist (Firewall + DNSmasq)..."
uci -q delete firewall.approved_domains
uci set firewall.approved_domains=ipset
uci set firewall.approved_domains.name='approved_domains'
uci set firewall.approved_domains.family='ipv4'
uci set firewall.approved_domains.match='dest_ip'

uci -q delete dhcp.approved_domains
uci set dhcp.approved_domains=ipset
# IMPORTANT: Name must be an add_list in OpenWrt 25.x for proper fw4 rendering
uci add_list dhcp.approved_domains.name='approved_domains'
uci add_list dhcp.approved_domains.domain='netflix.com'
uci add_list dhcp.approved_domains.domain='youtube.com'
uci add_list dhcp.approved_domains.domain='googlevideo.com'
uci add_list dhcp.approved_domains.domain='mtalk.google.com'
uci add_list dhcp.approved_domains.domain='google.com'
uci add_list dhcp.approved_domains.domain='googleapis.com'
uci add_list dhcp.approved_domains.domain='gstatic.com'
uci add_list dhcp.approved_domains.domain='time.android.com'
uci add_list dhcp.approved_domains.domain='pool.ntp.org'
# App Stores & Repositories
uci add_list dhcp.approved_domains.domain='f-droid.org'
uci add_list dhcp.approved_domains.domain='izzysoft.de'
uci add_list dhcp.approved_domains.domain='githubusercontent.com'
uci add_list dhcp.approved_domains.domain='codeberg.org'
uci add_list dhcp.approved_domains.domain='github.com'
uci add_list dhcp.approved_domains.domain='gitlab.com'
uci add_list dhcp.approved_domains.domain='auroraoss.com'
uci add_list dhcp.approved_domains.domain='gvt1.com'
uci add_list dhcp.approved_domains.domain='gvt2.com'

echo "7. Applying Strict Firewall Allow Rules..."
# Allow Jail to access AdGuard (Port 5353) and DHCP (Port 67)
uci -q delete firewall.jail_local
uci set firewall.jail_local=rule
uci set firewall.jail_local.name='Allow-Jail-AdGuard-DHCP'
uci set firewall.jail_local.src='jail'
uci set firewall.jail_local.dest_port='5353 67'
uci set firewall.jail_local.proto='tcp udp'
uci set firewall.jail_local.target='ACCEPT'

# Reject DNS-over-TLS (DoT) to prevent malware from bypassing AdGuard
uci -q delete firewall.reject_dot
uci set firewall.reject_dot=rule
uci set firewall.reject_dot.name='Reject-Jail-DoT'
uci set firewall.reject_dot.src='jail'
uci set firewall.reject_dot.dest_port='853'
uci set firewall.reject_dot.proto='tcp udp'
uci set firewall.reject_dot.target='REJECT'
uci set firewall.reject_dot.log='1' # Log if the device tries to sneak out via encrypted DNS

uci -q delete firewall.jail_approved
uci set firewall.jail_approved=rule
uci set firewall.jail_approved.name='Allow-Approved-Out'
uci set firewall.jail_approved.src='jail'
uci set firewall.jail_approved.dest='lan'
uci set firewall.jail_approved.ipset='approved_domains'
uci set firewall.jail_approved.proto='all'
uci set firewall.jail_approved.target='ACCEPT'

# Pinhole: Allow Jail to PC via Spacedesk
uci -q delete firewall.spacedesk
uci set firewall.spacedesk=rule
uci set firewall.spacedesk.name='Allow-Jail-to-PC-Spacedesk'
uci set firewall.spacedesk.src='jail'
uci set firewall.spacedesk.dest='lan'
uci set firewall.spacedesk.dest_ip="${SPACEDESK_IP}"
uci set firewall.spacedesk.dest_port="${SPACEDESK_PORT}"
uci set firewall.spacedesk.proto='tcp udp'
uci set firewall.spacedesk.target='ACCEPT'

# AIRPLAY: Allow local discovery and streaming to the projector
uci -q delete firewall.airplay_mdns
uci set firewall.airplay_mdns=rule
uci set firewall.airplay_mdns.name='Allow-AirPlay-mDNS'
uci set firewall.airplay_mdns.src='lan'
uci set firewall.airplay_mdns.dest='jail'
uci set firewall.airplay_mdns.dest_ip="${PROJECTOR_IP}"
uci set firewall.airplay_mdns.proto='udp'
uci set firewall.airplay_mdns.dest_port='5353'
uci set firewall.airplay_mdns.target='ACCEPT'

uci -q delete firewall.airplay_stream
uci set firewall.airplay_stream=rule
uci set firewall.airplay_stream.name='Allow-AirPlay-Stream'
uci set firewall.airplay_stream.src='lan'
uci set firewall.airplay_stream.dest='jail'
uci set firewall.airplay_stream.dest_ip="${PROJECTOR_IP}"
uci set firewall.airplay_stream.proto='tcp udp'
uci set firewall.airplay_stream.dest_port='5000 554 6000 7000 7001 7010 7011 7100 47000 49152-65535'
uci set firewall.airplay_stream.target='ACCEPT'

# AIRPLAY REFLECTOR: mDNS multicast (224.0.0.251:5353, TTL 1) does not
# cross subnets on its own. The unicast rules above do not deliver it.
# avahi-daemon on this AP reflects mDNS between lan and jail only.
# No WAN interface exists on this downstream AP, and no allow-interfaces
# value is pinned here: pin it to the `ip link` names for lan/jail only
# if other interfaces ever appear. This reflects ALL mDNS services, not
# just _airplay._tcp/_raop._tcp; avahi reflector has no per-service filter.
# It opens no unicast jail -> lan forwarding: it is mDNS-only, router-mediated.
# RISK, verify on live box: AdGuard in this script also uses port 5353
# for DNS. If avahi fails to bind IPv4 5353, check `logread -e avahi` and
# `ss -ulnp | grep 5353` before changing any port; do not move AdGuard
# blindly, that breaks the jail DNS intercept above.
if command -v apk >/dev/null 2>&1; then
    apk update
    apk add avahi-dbus-daemon dbus
else
    opkg update
    opkg install avahi-dbus-daemon dbus
fi
cat > /etc/avahi/avahi-daemon.conf << 'AVAHI_EOF'
[server]
use-ipv4=yes
use-ipv6=no
check-response-ttl=no
use-iff-running=no
[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
publish-domain=yes
[reflector]
enable-reflector=yes
reflect-ipv=no
AVAHI_EOF
/etc/init.d/dbus enable
/etc/init.d/dbus start
/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon restart

# Allow router to receive mDNS multicast from lan and jail (input to
# avahi-daemon itself, not forwarding). jail_local above already allows
# jail -> router unicast 5353; this covers the multicast address.
uci -q delete firewall.mdns_input_lan
uci set firewall.mdns_input_lan=rule
uci set firewall.mdns_input_lan.name='Allow-mDNS-Input-LAN'
uci set firewall.mdns_input_lan.src='lan'
uci set firewall.mdns_input_lan.proto='udp'
uci set firewall.mdns_input_lan.dest_ip='224.0.0.251'
uci set firewall.mdns_input_lan.dest_port='5353'
uci set firewall.mdns_input_lan.target='ACCEPT'

uci -q delete firewall.mdns_input_jail
uci set firewall.mdns_input_jail=rule
uci set firewall.mdns_input_jail.name='Allow-mDNS-Input-Jail'
uci set firewall.mdns_input_jail.src='jail'
uci set firewall.mdns_input_jail.proto='udp'
uci set firewall.mdns_input_jail.dest_ip='224.0.0.251'
uci set firewall.mdns_input_jail.dest_port='5353'
uci set firewall.mdns_input_jail.target='ACCEPT'

# Forwarding: Allow LAN zone to forward traffic into Jail zone
uci -q delete firewall.lan_to_jail
uci set firewall.lan_to_jail=forwarding
uci set firewall.lan_to_jail.src='lan'
uci set firewall.lan_to_jail.dest='jail'

# Pinhole: Port Forward (DNAT) from LAN Router IP -> Projector File Explorer
uci -q delete firewall.fwd_file_explorer
uci set firewall.fwd_file_explorer=redirect
uci set firewall.fwd_file_explorer.name='Port-Forward-File-Explorer'
uci set firewall.fwd_file_explorer.src='lan'
uci set firewall.fwd_file_explorer.src_dport="8000"
uci set firewall.fwd_file_explorer.dest='jail'
uci set firewall.fwd_file_explorer.dest_ip="${PROJECTOR_IP}"
uci set firewall.fwd_file_explorer.dest_port="8000"
uci set firewall.fwd_file_explorer.proto='tcp'
uci set firewall.fwd_file_explorer.target='DNAT'

# Pinhole: Port Forward (DNAT) from LAN Router IP -> Projector ADB
uci -q delete firewall.fwd_adb
uci set firewall.fwd_adb=redirect
uci set firewall.fwd_adb.name='Port-Forward-ADB'
uci set firewall.fwd_adb.src='lan'
uci set firewall.fwd_adb.src_dport='5555'
uci set firewall.fwd_adb.dest='jail'
uci set firewall.fwd_adb.dest_ip="${PROJECTOR_IP}"
uci set firewall.fwd_adb.dest_port='5555'
uci set firewall.fwd_adb.proto='tcp'
uci set firewall.fwd_adb.target='DNAT'

# THE FIX: Explicitly log and reject all other traffic trying to leave the jail to the LAN/Internet.
# Placed AFTER the allow rules. This patches the fw4 `oifname` default reject bypass.
uci -q delete firewall.jail_reject_all
uci set firewall.jail_reject_all=rule
uci set firewall.jail_reject_all.name='Reject-All-Unapproved-Jail'
uci set firewall.jail_reject_all.src='jail'
uci set firewall.jail_reject_all.dest='lan'
uci set firewall.jail_reject_all.target='REJECT'
uci set firewall.jail_reject_all.log='1'
uci set firewall.jail_reject_all.log_limit='10/minute' 

echo "8. Creating Placeholder Wi-Fi Network..."
uci set wireless.jail_wifi=wifi-iface
uci set wireless.jail_wifi.device="${WIFI_DEVICE}"
uci set wireless.jail_wifi.network='jail'
uci set wireless.jail_wifi.mode='ap'
uci set wireless.jail_wifi.ssid="${WIFI_SSID}"
uci set wireless.jail_wifi.encryption='sae'
uci set wireless.jail_wifi.key="${WIFI_KEY}"
uci set wireless.jail_wifi.disabled="${WIFI_DISABLED}"

echo "9. Committing changes and restarting services..."
uci commit
/etc/init.d/network reload
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

echo "Done! Strict isolation achieved."
EOF

chmod +x setup-isolated-jail.sh
