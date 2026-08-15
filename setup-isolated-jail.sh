cat << 'EOF' > setup-isolated-jail.sh
#!/bin/sh
# ---------------------------------------------------------
# Strictly Isolated Zero-Trust IoT Jail & AdGuard Home
# Compatible with OpenWrt 25.x (fw4/nftables & apk)
# Zero modifications to global LAN or DNSmasq configs
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
uci set network.jail.ipaddr='192.168.99.1'
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

echo "4. Creating targeted Masquerade ONLY for the jail..."
# Wipe any existing section first to prevent UCI ghost variables
uci -q delete firewall.jail_nat

# In fw4 'config nat', 'src' is the EGRESS interface.
# This masquerades traffic leaving the 'lan' interface, but ONLY if it comes from the jail.
uci set firewall.jail_nat=nat
uci set firewall.jail_nat.name='Masquerade-Jail'
uci set firewall.jail_nat.src='lan'
uci set firewall.jail_nat.src_ip='192.168.99.0/24'
uci set firewall.jail_nat.proto='all'
uci set firewall.jail_nat.target='MASQUERADE'

echo "5. Forcing Jail DNS into AdGuard (Targeted Intercept)..."
# Intercepts port 53 traffic exclusively from the jail zone and routes it to AdGuard on 5353
uci set firewall.jail_dns_intercept=redirect
uci set firewall.jail_dns_intercept.name='Intercept-Jail-DNS'
uci set firewall.jail_dns_intercept.src='jail'
uci set firewall.jail_dns_intercept.src_dport='53'
uci set firewall.jail_dns_intercept.dest='jail'
uci set firewall.jail_dns_intercept.dest_port='5353'
uci set firewall.jail_dns_intercept.proto='tcp udp'

echo "6. Creating dynamic Domain Allowlist (Firewall + DNSmasq)..."
# 6a. Explicitly declare the ipset in Firewall for fw4/nftables initialization
uci set firewall.approved_domains=ipset
uci set firewall.approved_domains.name='approved_domains'
uci set firewall.approved_domains.family='ipv4'
uci set firewall.approved_domains.match='dest_ip'

# 6b. Configure DNSmasq to populate the set upon DNS lookup
uci -q delete dhcp.approved_domains
uci set dhcp.approved_domains=ipset
# IMPORTANT: Name must be an add_list in OpenWrt 25.x for proper fw4 rendering
uci add_list dhcp.approved_domains.name='approved_domains'
# Base Domains
uci add_list dhcp.approved_domains.domain='netflix.com'
uci add_list dhcp.approved_domains.domain='youtube.com'
uci add_list dhcp.approved_domains.domain='googlevideo.com'
# App Store & Push Notification Domains
uci add_list dhcp.approved_domains.domain='mtalk.google.com'
uci add_list dhcp.approved_domains.domain='google.com'
uci add_list dhcp.approved_domains.domain='googleapis.com'
uci add_list dhcp.approved_domains.domain='gstatic.com'

echo "7. Applying Strict Firewall Allow Rules..."
# Allow Jail to access AdGuard (Port 5353) and DHCP (Port 67)
uci set firewall.jail_local=rule
uci set firewall.jail_local.name='Allow-Jail-AdGuard-DHCP'
uci set firewall.jail_local.src='jail'
uci set firewall.jail_local.dest_port='5353 67'
uci set firewall.jail_local.proto='tcp udp'
uci set firewall.jail_local.target='ACCEPT'

# Reject DNS-over-TLS (DoT) to prevent malware from bypassing AdGuard
uci set firewall.reject_dot=rule
uci set firewall.reject_dot.name='Reject-Jail-DoT'
uci set firewall.reject_dot.src='jail'
uci set firewall.reject_dot.dest_port='853'
uci set firewall.reject_dot.proto='tcp udp'
uci set firewall.reject_dot.target='REJECT'
uci set firewall.reject_dot.log='1' # Log if the device tries to sneak out via encrypted DNS

# Allow Jail to reach the internet ONLY for IPs in the approved domain list
uci set firewall.jail_approved=rule
uci set firewall.jail_approved.name='Allow-Approved-Out'
uci set firewall.jail_approved.src='jail'
uci set firewall.jail_approved.dest='lan'
uci set firewall.jail_approved.ipset='approved_domains'
uci set firewall.jail_approved.proto='all'
uci set firewall.jail_approved.target='ACCEPT'

# Pinhole: Allow Jail to PC via Spacedesk
# ---> CHANGE 192.168.1.X TO YOUR PC's IP ADDRESS! <---
uci set firewall.spacedesk=rule
uci set firewall.spacedesk.name='Allow-Jail-to-PC-Spacedesk'
uci set firewall.spacedesk.src='jail'
uci set firewall.spacedesk.dest='lan'
uci set firewall.spacedesk.dest_ip='192.168.1.X'
uci set firewall.spacedesk.dest_port='28252'
uci set firewall.spacedesk.proto='tcp udp'
uci set firewall.spacedesk.target='ACCEPT'

# THE FIX: Explicitly log and reject all other traffic trying to leave the jail to the LAN/Internet.
# Placed AFTER the allow rules. This patches the fw4 `oifname` default reject bypass.
uci set firewall.jail_reject_all=rule
uci set firewall.jail_reject_all.name='Reject-All-Unapproved-Jail'
uci set firewall.jail_reject_all.src='jail'
uci set firewall.jail_reject_all.dest='lan'
uci set firewall.jail_reject_all.target='REJECT'
uci set firewall.jail_reject_all.log='1' # <-- THIS IS WHAT YOU WERE MISSING
# (Optional) Limit the log so a misbehaving device doesn't crash your router's memory
uci set firewall.jail_reject_all.log_limit='10/minute' 

echo "8. Creating Placeholder Wi-Fi Network..."
uci set wireless.jail_wifi=wifi-iface
uci set wireless.jail_wifi.device='radio2'
uci set wireless.jail_wifi.network='jail'
uci set wireless.jail_wifi.mode='ap'
uci set wireless.jail_wifi.ssid='projectorwifi'
uci set wireless.jail_wifi.encryption='psk2'
uci set wireless.jail_wifi.key='password'
uci set wireless.jail_wifi.disabled='1'

echo "9. Committing changes and restarting services..."
uci commit
/etc/init.d/network reload
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

echo "Done! Strict isolation achieved."
EOF

chmod +x setup-isolated-jail.sh