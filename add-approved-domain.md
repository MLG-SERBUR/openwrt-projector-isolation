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