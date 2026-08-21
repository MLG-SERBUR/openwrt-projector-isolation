# What this is

Uses OpenWRT to create an isolated network with
- whitelisted domains
- port forwarding/masquerading for specific services

Initially created for a projector using Android that has some built-in malware (TODO: list info about this cheap projector)

---

# Add an approved domain

### The Complete 3-Step Process:

```bash
uci add_list dhcp.approved_domains.domain='whatever.com'
uci commit dhcp
/etc/init.d/dnsmasq reload
```

---

### Important Things to Keep in Mind:

1. **Subdomains are included automatically:**  
   Adding `whatever.com` automatically matches `api.whatever.com`, `cdn.whatever.com`, etc. You don't need to add each subdomain individually.

2. **The firewall doesn't open until a DNS query happens:**  
   Reloading dnsmasq does not instantly open the firewall. Dnsmasq only adds the IP address to the firewall's allowed set **when the device actually requests a DNS lookup** for that domain.  
   *(If the device has the IP cached locally from earlier, it might fail until its internal DNS cache expires or you reconnect it to the Wi-Fi).*

3. **How to verify it’s working:**
   * View all approved domains in your config:
     ```bash
     uci show dhcp.approved_domains
     ```
   * See the actual IP addresses that dnsmasq has dynamically added to the firewall allowlist:
     ```bash
     nft list set inet fw4 approved_domains
     ```

# Reading rejected IPs

Here are the exact `logread` commands depending on how you want to view the rejected traffic:

### 1. Watch Rejected Traffic in Real-Time (Live Feed)
Leave this running in your terminal while you test the projector. Every time a connection gets blocked, it will pop up live:
```bash
logread -f -e Reject
```
*(Press `Ctrl + C` to stop watching).*

---

### 2. View Past Rejections (Full Details)
To see all recent blocked connections stored in the router's memory:
```bash
logread -e Reject-All-Unapproved-Jail
```
*(If you want to see if the device tried to sneak out via encrypted DNS, you can also run `logread -e Reject-Jail-DoT`).*

---

### 3. Clean & Readable View (Only IPs, Ports & Protocols)
The raw kernel logs have a lot of noise (MAC addresses, TCP window flags, TTLs). 

If you just want a clean list showing **Source IP -> Destination IP : Port**, run this one-liner:
```bash
logread -e Reject-All-Unapproved-Jail | awk '{for(i=1;i<=NF;i++) if($i ~ /^(SRC|DST|DPT|PROTO)=/) printf "%s ", $i; print ""}'
```
**Example output:**
```text
SRC=192.168.99.101 DST=118.123.245.136 PROTO=TCP DPT=9090 
SRC=192.168.99.101 DST=144.76.109.58 PROTO=TCP DPT=443 
```

---

### 4. Find the Top 10 Most Frequently Blocked IPs
To quickly see which external servers the projector is spamming the most:
```bash
logread -e Reject-All-Unapproved-Jail | grep -o 'DST=[^ ]*' | sort | uniq -c | sort -nr | head -n 10
```


To make the clean `awk` output update continuously in real-time, add the `-f` (follow) flag to `logread`, and use `fflush()` so `awk` prints each line instantly without buffering.

### 1. Live Feed (Clean Output)
```bash
logread -f -e Reject-All-Unapproved-Jail | awk '{for(i=1;i<=NF;i++) if($i ~ /^(SRC|DST|DPT|PROTO)=/) printf "%s ", $i; print ""; fflush()}'
```

---

### 2. Live Feed with Timestamps (Recommended)
Since it is a live feed, adding the time of the block helps you see *when* the projector is trying to phone home:

```bash
logread -f -e Reject-All-Unapproved-Jail | awk '{printf "[%s %s] ", $2, $3; for(i=1;i<=NF;i++) if($i ~ /^(SRC|DST|DPT|PROTO)=/) printf "%s ", $i; print ""; fflush()}'
```

**Example output:**
```text
[Aug 21 07:33:30] SRC=192.168.99.101 DST=118.123.245.136 PROTO=TCP DPT=9090 
[Aug 21 07:33:36] SRC=192.168.99.101 DST=144.76.109.58 PROTO=TCP DPT=443 
```

*(Press `Ctrl + C` at any time to stop the feed).*