# Hass.io Access Point
Use your hass.io host as a WiFi access point - perfect for off-grid and security focused installations.

## Main features
- Create a WiFi access point with built-in (Raspberry Pi) or external WiFi (USB) cards (using hostapd)
- **2.4GHz or 5GHz operation** (802.11n, optional 802.11ac on 5GHz)
- Hidden or visible SSIDs
- DHCP server (Optional. Uses dnsmasq)
- MAC address filtering (allow/deny)
- Internet routing for clients (Optional)


## Installation

Please add
`https://github.com/DrakeCaesar/Hassio-Access-Point` to your hass.io addon repositories list. If you're not sure how, see [instructions](https://www.home-assistant.io/hassio/installing_third_party_addons/) on the Home Assistant website.

> This is a fork of [ex-ml/hassio-access-point](https://github.com/ex-ml/Hassio-Access-Point) that adds 5GHz
> support. If you already had the upstream repository added, it will show up as a separate repository entry
> with the same add-on. Remove the upstream repository if you only want this fork installed.

## Config

All of the options below are shown in the add-on's **Configuration** tab, so nothing is hidden behind a
hand-edited options file. Options you can leave blank (`ht_capab`, `vht_capab`) fall back to a sensible
default automatically.

### Options
- **ssid** (**required**): The name of your access point
- **wpa_passphrase** (**required**): The passkey for your access point
- **band** (_optional_): Which band to host the AP on. `2.4` (default) or `5`. The built-in radio on Raspberry Pi 3B+ and later is dual-band; earlier models are 2.4GHz-only
- **channel** (**required**): The WiFi channel to use. 2.4GHz: 1-13 (1, 6 or 11 recommended). 5GHz: e.g. 36, 40, 44, 48, 100, 149 or 157
- **address** (**required**): The address of your hass.io WiFi card/network
- **netmask** (**required**): Subnet mask of the network
- **broadcast** (**required**): Broadcast address of the network
- **interface** (_optional_): Which wlan card to use. Default: wlan0
- **hide_ssid** (_optional_): Whether SSID is visible or hidden. 0 = visible, 1 = hidden. Defaults to visible
- **dhcp** (_optional_): Enable or disable DHCP server. 0 = disable, 1 = enable. Defaults to disabled
- **dhcp_start_addr** (_optional_): Start address for DHCP range. Required if DHCP enabled
- **dhcp_end_addr** (_optional_): End address for DHCP range. Required if DHCP enabled
- **allow_mac_addresses** (_optional_): List of MAC addresses to allow. Note: if using allow, blocks everything not in list
- **deny_mac_addresses** (_optional_): List of MAC addresses to block. Note: if using deny, allows everything not in list
- **debug** (_optional_): Set logging level. 0 = basic output, 1 = show addon detail, 2 = same as 1 plus run hostapd in debug mode
- **ht_capab** (_optional_): Set WiFi adapter's HT capabilities. Leave blank to use the default, which is `[HT40][SHORT-GI-20][DSSS_CCK-40]` on 2.4GHz and `[HT40+][SHORT-GI-20][SHORT-GI-40]` on 5GHz
- **ieee80211ac** (_optional_): Enable 802.11ac (VHT) on the 5GHz band. Only enable if your WiFi card supports 802.11ac. Defaults to disabled
- **vht_capab** (_optional_): Set WiFi adapter's VHT capabilities when 802.11ac is enabled, e.g. `[SHORT-GI-20][SHORT-GI-40][SHORT-GI-80]`. Leave blank to omit
- **country_code** (_optional_): Two-letter country code (e.g. `GB`) used to set the WiFi regulatory domain. Required for most 5GHz channels to be usable
- **hostapd_config_override** (_optional_): List of hostapd config options to add to hostapd.conf (can be used to override existing options)
- **client_internet_access** (_optional_): Provide internet access for clients. 1 = enable
- **client_dns_override** (_optional_): Specify list of DNS servers for clients. Requires DHCP to be enabled. Note: Add-on will try to use DNS servers of the parent host by default.
- **dnsmasq_config_override** (_optional_): List of dnsmasq config options to add to dnsmasq.conf (can be used to override existing options, as well as reserving IPs, e.g. `dhcp-host=12:34:56:78:90:AB,192.168.99.123`)

Note: use either allow or deny lists for MAC filtering. If using allow, deny will be ignored.

### Example configuration

```
    "ssid": "AP-NAME",
    "wpa_passphrase": "AP-PASSWORD",
    "band": "2.4",
    "channel": "6",
    "address": "192.168.10.1",
    "netmask": "255.255.255.0",
    "broadcast": "192.168.10.255",
    "interface": "wlan0",
    "hide_ssid": "1",
    "dhcp": "1",
    "dhcp_start_addr": "192.168.10.10",
    "dhcp_end_addr": "192.168.10.20",
    "allow_mac_addresses": [],
    "deny_mac_addresses": ['ab:cd:ef:fe:dc:ba'],
    "debug": "0",
    "ieee80211ac": false,
    "hostapd_config_override": [],
    "client_internet_access": '1',
    "client_dns_override": ['1.1.1.1', '8.8.8.8']
```

### 5GHz example configuration

```
    "ssid": "AP-NAME-5G",
    "wpa_passphrase": "AP-PASSWORD",
    "band": "5",
    "channel": "36",
    "address": "192.168.10.1",
    "netmask": "255.255.255.0",
    "broadcast": "192.168.10.255",
    "interface": "wlan0",
    "country_code": "GB",
    "ieee80211ac": true,
    "vht_capab": "[SHORT-GI-20][SHORT-GI-40][SHORT-GI-80]"
```

### Notes on 5GHz operation

- Set **band** to `5` and pick a 5GHz **channel**. A channel below 36 is rejected at startup.
- On Raspberry Pi 3B+ and later (including the Pi 4 and Pi 5) the **built-in** wireless radio is dual-band,
  so `interface: wlan0` works on 5GHz without a USB adapter. Only the Pi 3B+ onward have 5GHz hardware;
  the Pi 3B and older are 2.4GHz-only. An external USB adapter is usually `wlan1`.
- Set **country_code** to your two-letter country code. On dual-band Raspberry Pi models the radio is
  disabled for 5GHz operation until a WLAN country is known, and hostapd will refuse to start on many
  channels without it.
- The built-in Pi radio is 1x1 802.11ac, so it tops out at 80MHz. Don't enable `[SHORT-GI-160]` in
  `vht_capab`; use `[SHORT-GI-20][SHORT-GI-40][SHORT-GI-80]` at most.
- Some 5GHz channels (52-144) are DFS channels that must scan for radar before transmitting, which can add
  60s+ to startup, and DFS support in the Pi's `brcmfmac` firmware is unreliable. Prefer 36-48 or 149-165.
- Only one band can be hosted per add-on instance. If you want both 2.4GHz and 5GHz simultaneously, run a
  second copy of the add-on on a different interface and subnet.

If the add-on fails to start on 5GHz, set `debug: 1` and check the regulatory domain it reports. The
regulatory domain must list your chosen channel as usable for AP operation. Setting `country_code` in the
add-on covers this, but the host OS WLAN country must also be configured on some HAOS installs.

### Device & OS compatibility

New releases will always be tested on the latest Home Assistant OS using Raspberry Pi 3B+ and Pi 4, but existing versions won't be proactively tested when new Home Assistant OS/Supervisor versions are released. If a new HAOS/Supervisor version breaks something, please raise an issue.

This add-on should work with 32 & 64 bit HAOS, and has also been tested on Debian 10 with Home Assistant Supervised.
