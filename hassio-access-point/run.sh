#!/usr/bin/with-contenv bashio

BRIDGE_NAME=br0
BRIDGE_ENABLED=false
FIVE_GHZ_CHANNELS="36 40 44 48 52 56 60 64 100 104 108 112 116 120 124 128 132 136 140 144 149 153 157 161 165"

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	for iface in $MANAGED_INTERFACES ; do
		ifdown $iface
		ip link set $iface down
		ip addr flush dev $iface
	done
	if [ "$BRIDGE_ENABLED" == "true" ] ; then
		ifdown $BRIDGE_NAME
		ip addr flush dev $BRIDGE_NAME
		ip link set $BRIDGE_NAME down
		ip link del $BRIDGE_NAME 2>/dev/null || true
	fi
	exit 0
}

# Logging function to set verbosity of output to addon log
logger(){
    msg=$1
    level=$2
    if [ $DEBUG -ge $level ]; then
        echo $msg
    fi
}

optional_config(){
    local value
    value=$(bashio::config "$1")
    case "$value" in
        null|false) echo "" ;;
        *) echo "$value" ;;
    esac
}

CONFIG_PATH=/data/options.json

INTERFACE_24=$(optional_config 'general.interface_2_4ghz')
INTERFACE_5=$(optional_config 'general.interface_5ghz')
COUNTRY_CODE=$(optional_config 'general.country_code')
ADDRESS=$(bashio::config 'general.address')
NETMASK=$(bashio::config 'general.netmask')
BROADCAST=$(bashio::config 'general.broadcast')
DHCP=$(bashio::config.false 'general.dhcp'; echo $?)
DHCP_START_ADDR=$(bashio::config 'general.dhcp_start_addr' )
DHCP_END_ADDR=$(bashio::config 'general.dhcp_end_addr' )
ALLOW_MAC_ADDRESSES=$(bashio::config 'general.allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'general.deny_mac_addresses' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'general.client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'general.client_dns_override' )
DEBUG=$(bashio::config 'general.debug' )
HOSTAPD_CONFIG_OVERRIDE=$(bashio::config 'general.hostapd_config_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'general.dnsmasq_config_override' )

# Per band settings. A band only runs when its interface is set, so an unused
# band does not need an SSID or a password.
SSID_24=$(bashio::config 'band_2_4ghz.ssid')
WPA_PASSPHRASE_24=$(bashio::config 'band_2_4ghz.wpa_passphrase')
HIDE_SSID_24=$(bashio::config.false 'band_2_4ghz.hide_ssid'; echo $?)
CHANNEL_24=$(bashio::config 'band_2_4ghz.channel' 6)
HT_CAPAB_24=$(optional_config 'band_2_4ghz.ht_capab')

SSID_5=$(bashio::config 'band_5ghz.ssid')
WPA_PASSPHRASE_5=$(bashio::config 'band_5ghz.wpa_passphrase')
HIDE_SSID_5=$(bashio::config.false 'band_5ghz.hide_ssid'; echo $?)
CHANNEL_5=$(bashio::config 'band_5ghz.channel' 44)
HT_CAPAB_5=$(optional_config 'band_5ghz.ht_capab')
IEEE80211AC_5=$(bashio::config 'band_5ghz.ieee80211ac' 'true')
VHT_CAPAB_5=$(optional_config 'band_5ghz.vht_capab')
DFS_5=$(bashio::config 'band_5ghz.dfs' 'false')

# Get the Default Route interface
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5 }')

# Wireless interfaces the kernel knows about, so a mis-typed interface_2 is obvious
DETECTED_WIRELESS=""
for dev in /sys/class/net/* ; do
    [ -e "$dev/wireless" ] || [ -e "$dev/phy80211" ] || continue
    DETECTED_WIRELESS="$DETECTED_WIRELESS $(basename "$dev")"
done
DETECTED_WIRELESS=${DETECTED_WIRELESS# }

echo "Starting Hass.io Access Point Addon"

# A band runs when its interface is set, and each band gets its own radio. With
# both bands active the two radios share one network through a bridge.
MANAGED_INTERFACES=""
RADIO_IFACES=()
RADIO_BANDS=()
if [ -n "$INTERFACE_24" ] ; then
    MANAGED_INTERFACES="$INTERFACE_24"
    RADIO_IFACES+=("$INTERFACE_24")
    RADIO_BANDS+=("2.4")
fi
if [ -n "$INTERFACE_5" ] ; then
    if [ "$INTERFACE_5" == "$INTERFACE_24" ] ; then
        bashio::exit.nok "interface_2_4ghz and interface_5ghz are both '$INTERFACE_5'. Each band needs its own radio."
    fi
    MANAGED_INTERFACES="$MANAGED_INTERFACES $INTERFACE_5"
    RADIO_IFACES+=("$INTERFACE_5")
    RADIO_BANDS+=("5")
fi
MANAGED_INTERFACES=${MANAGED_INTERFACES# }

if [ ${#RADIO_IFACES[@]} -eq 0 ] ; then
    bashio::exit.nok "Neither interface_2_4ghz nor interface_5ghz is set, so there is no radio to run an access point on. Wireless interfaces on this host: ${DETECTED_WIRELESS:-none}."
fi

for iface in $MANAGED_INTERFACES ; do
    if [ ! -e "/sys/class/net/$iface/wireless" ] && [ ! -e "/sys/class/net/$iface/phy80211" ] ; then
        bashio::exit.nok "'$iface' is not a wireless interface. Wireless interfaces on this host: ${DETECTED_WIRELESS:-none}."
    fi
done

if [ ${#RADIO_IFACES[@]} -gt 1 ] ; then
    BRIDGE_ENABLED=true
    TARGET_INTERFACE=$BRIDGE_NAME
else
    TARGET_INTERFACE=$MANAGED_INTERFACES
fi

# Printed at debug 0 on purpose: this is what you need to fill in the interfaces
logger "Wireless interfaces found: ${DETECTED_WIRELESS:-none}" 0
if [ "$BRIDGE_ENABLED" == "true" ] ; then
    logger "Both bands: 2.4GHz on $INTERFACE_24, 5GHz on $INTERFACE_5, bridged as $BRIDGE_NAME" 0
else
    logger "One band on $TARGET_INTERFACE. Set the other interface in General to run both at once." 0
fi

# Setup interface
logger "# Setup interface:" 1
for iface in $MANAGED_INTERFACES ; do
    logger "Run command: nmcli dev set $iface managed no" 1
    nmcli dev set $iface managed no

    logger "Run command: ip link set $iface down" 1
    ip link set $iface down
done

# hostapd adds each radio to the bridge once it starts, so the radios stay down
if [ "$BRIDGE_ENABLED" == "true" ] ; then
    logger "# Both radios share one network through $BRIDGE_NAME:" 1
    logger "Run command: ip link add name $BRIDGE_NAME type bridge" 1
    ip link add name $BRIDGE_NAME type bridge 2>/dev/null || true
fi

# Create and add our interface to interfaces file
logger "Add to /etc/network/interfaces: iface $TARGET_INTERFACE inet static" 1
echo "iface $TARGET_INTERFACE inet static"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: address $ADDRESS" 1
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: broadcast $BROADCAST" 1
echo "broadcast $BROADCAST"$'\n' >> /etc/network/interfaces

logger "Run command: ip link set $TARGET_INTERFACE up" 1
ip link set $TARGET_INTERFACE up

# Setup signal handlers
trap 'term_handler' SIGTERM

# Enforces required env variables
required_vars=(general.address general.netmask general.broadcast)
for required_var in "${required_vars[@]}"; do
    bashio::config.require $required_var "An AP cannot be created without this information"
done

# Credentials are per band, and only needed for the bands that actually run
validate_band_credentials(){
    local band=$1
    local ssid=$2
    local passphrase=$3

    if ! [[ "$ssid" =~ ^.{2,32}$ ]] ; then
        bashio::exit.nok "The $band band needs an SSID between 2 and 32 characters long. Set it in the $band block."
    fi
    if [ ${#passphrase} -lt 8 ] ; then
        bashio::exit.nok "The WPA password for $band must be at least 8 characters long."
    fi
}

for radio in "${!RADIO_IFACES[@]}" ; do
    if [ "${RADIO_BANDS[$radio]}" == "5" ] ; then
        validate_band_credentials "5GHz" "$SSID_5" "$WPA_PASSPHRASE_5"
    else
        validate_band_credentials "2.4GHz" "$SSID_24" "$WPA_PASSPHRASE_24"
    fi
done

FLAG_LIST_REGEX='^(\[[A-Z0-9][A-Z0-9_+-]*\])+$'
if [ -n "$HT_CAPAB_24" ] && ! [[ "$HT_CAPAB_24" =~ $FLAG_LIST_REGEX ]] ; then
    bashio::exit.nok "band_2_4ghz.ht_capab must be a list of flags in square brackets, e.g. '[HT40+][SHORT-GI-20]'. Got: $HT_CAPAB_24"
fi
if [ -n "$HT_CAPAB_5" ] && ! [[ "$HT_CAPAB_5" =~ $FLAG_LIST_REGEX ]] ; then
    bashio::exit.nok "band_5ghz.ht_capab must be a list of flags in square brackets, e.g. '[HT40+][SHORT-GI-20]'. Got: $HT_CAPAB_5"
fi
if [ -n "$VHT_CAPAB_5" ] && ! [[ "$VHT_CAPAB_5" =~ $FLAG_LIST_REGEX ]] ; then
    bashio::exit.nok "band_5ghz.vht_capab must be a list of flags in square brackets, e.g. '[SHORT-GI-80]'. Got: $VHT_CAPAB_5"
fi
if [ -n "$COUNTRY_CODE" ] && ! [[ "$COUNTRY_CODE" =~ ^[A-Z]{2}$ ]] ; then
    bashio::exit.nok "country_code must be a two-letter uppercase country code, e.g. 'GB'. Got: $COUNTRY_CODE"
fi

# Resolve everything that depends on the band a radio runs on. The 2.4GHz and
# 5GHz settings are held apart, so moving a radio between bands is one change.
# Sets: RADIO_HW_MODE RADIO_CHANNEL RADIO_HT_CAPAB RADIO_VHT_CAPAB RADIO_AC
#       RADIO_IS_DFS RADIO_HT40_ENABLED RADIO_VHT_CENTER
resolve_band(){
    local band=$1
    local ht40_mode default_ht_capab

    if [ "$band" == "5" ] ; then
        RADIO_SSID=$SSID_5
        RADIO_WPA_PASSPHRASE=$WPA_PASSPHRASE_5
        RADIO_HIDE_SSID=$HIDE_SSID_5
        RADIO_HW_MODE=a
        RADIO_CHANNEL=$CHANNEL_5
        RADIO_HT_CAPAB=$HT_CAPAB_5
        RADIO_VHT_CAPAB=$VHT_CAPAB_5
        RADIO_AC=$IEEE80211AC_5
        if ! [[ " $FIVE_GHZ_CHANNELS " == *" $RADIO_CHANNEL "* ]] ; then
            bashio::exit.nok "Channel $RADIO_CHANNEL is not a 5GHz WiFi channel. Use 36, 40, 44 or 48 (non-DFS), or 149, 153, 157, 161 or 165 where your region allows it."
        fi
        if [ "$RADIO_CHANNEL" -eq 48 ] || [ "$RADIO_CHANNEL" -eq 165 ] ; then
            ht40_mode=HT40-
        else
            ht40_mode=HT40+
        fi
        default_ht_capab="[$ht40_mode][SHORT-GI-20][SHORT-GI-40]"
        if [ "$RADIO_CHANNEL" -ge 52 ] && [ "$RADIO_CHANNEL" -le 144 ] ; then
            RADIO_IS_DFS=true
        else
            RADIO_IS_DFS=false
        fi
    else
        RADIO_SSID=$SSID_24
        RADIO_WPA_PASSPHRASE=$WPA_PASSPHRASE_24
        RADIO_HIDE_SSID=$HIDE_SSID_24
        RADIO_HW_MODE=g
        RADIO_CHANNEL=$CHANNEL_24
        RADIO_HT_CAPAB=$HT_CAPAB_24
        RADIO_VHT_CAPAB=""
        RADIO_AC=false
        RADIO_IS_DFS=false
        default_ht_capab="[SHORT-GI-20][DSSS_CCK-40]"
        if [ "$RADIO_CHANNEL" -lt 1 ] || [ "$RADIO_CHANNEL" -gt 13 ] ; then
            bashio::exit.nok "Channel $RADIO_CHANNEL is not valid for the 2.4GHz band. Use a channel between 1 and 13."
        fi
    fi

    if [ -z "$RADIO_HT_CAPAB" ] ; then
        RADIO_HT_CAPAB=$default_ht_capab
    fi

    case "$RADIO_HT_CAPAB" in
        *"[HT40+]"*|*"[HT40-]"*) RADIO_HT40_ENABLED=true ;;
        *)                       RADIO_HT40_ENABLED=false ;;
    esac

    case "$RADIO_CHANNEL" in
        36|40|44|48)      RADIO_VHT_CENTER=42 ;;
        52|56|60|64)      RADIO_VHT_CENTER=58 ;;
        100|104|108|112)  RADIO_VHT_CENTER=106 ;;
        116|120|124|128)  RADIO_VHT_CENTER=122 ;;
        132|136|140|144)  RADIO_VHT_CENTER=138 ;;
        149|153|157|161)  RADIO_VHT_CENTER=155 ;;
        *)               RADIO_VHT_CENTER="" ;;
    esac

    if [ "$RADIO_IS_DFS" == "true" ] ; then
        if [ "$DFS_5" != "true" ] ; then
            bashio::exit.nok "Channel $RADIO_CHANNEL is a DFS channel (52-144). It must listen for radar before it may transmit, and the Raspberry Pi radios cannot do that. Use a non-DFS channel: 36, 40, 44, 48, or 149, 153, 157, 161, 165 where your region allows it, or set 'dfs_5g' to true if your adapter supports radar detection."
        fi
        if [ -z "$COUNTRY_CODE" ] ; then
            bashio::exit.nok "DFS channel $RADIO_CHANNEL needs a regulatory domain. Set 'country_code' to your two-letter country code."
        fi
    fi
}

# Build one hostapd config for one radio
write_hostapd_conf(){
    local iface=$1
    local band=$2
    local conf=$3

    resolve_band "$band"

    logger "# Setup hostapd for $iface ($band GHz):" 1
    cp /hostapd.conf.template "$conf"

    logger "Add to $conf: ssid=$RADIO_SSID" 1
    echo "ssid=$RADIO_SSID"$'\n' >> "$conf"
    logger "Add to $conf: wpa_passphrase=********" 1
    echo "wpa_passphrase=$RADIO_WPA_PASSPHRASE"$'\n' >> "$conf"
    logger "Add to $conf: interface=$iface" 1
    echo "interface=$iface"$'\n' >> "$conf"
    logger "Add to $conf: hw_mode=$RADIO_HW_MODE (band $band GHz)" 1
    echo "hw_mode=$RADIO_HW_MODE"$'\n' >> "$conf"
    logger "Add to $conf: channel=$RADIO_CHANNEL" 1
    echo "channel=$RADIO_CHANNEL"$'\n' >> "$conf"
    logger "Add to $conf: ignore_broadcast_ssid=$RADIO_HIDE_SSID" 1
    echo "ignore_broadcast_ssid=$RADIO_HIDE_SSID"$'\n' >> "$conf"
    logger "Add to $conf: ieee80211n=1" 1
    echo "ieee80211n=1"$'\n' >> "$conf"
    logger "Add to $conf: ht_capab=$RADIO_HT_CAPAB" 1
    echo "ht_capab=$RADIO_HT_CAPAB"$'\n' >> "$conf"

    if [ "$band" == "5" ] && [ "$RADIO_AC" == "true" ] ; then
        logger "Add to $conf: ieee80211ac=1" 1
        echo "ieee80211ac=1"$'\n' >> "$conf"
        if [ -n "$RADIO_VHT_CAPAB" ] ; then
            logger "Add to $conf: vht_capab=$RADIO_VHT_CAPAB" 1
            echo "vht_capab=$RADIO_VHT_CAPAB"$'\n' >> "$conf"
        fi
        if [ "$RADIO_HT40_ENABLED" != "true" ] ; then
            logger "ht_capab has no [HT40+] or [HT40-], so VHT stays at 20/40MHz." 1
        elif [ -n "$RADIO_VHT_CENTER" ] ; then
            logger "Add to $conf: vht_oper_chwidth=1" 1
            echo "vht_oper_chwidth=1"$'\n' >> "$conf"
            logger "Add to $conf: vht_oper_centr_freq_seg0_idx=$RADIO_VHT_CENTER" 1
            echo "vht_oper_centr_freq_seg0_idx=$RADIO_VHT_CENTER"$'\n' >> "$conf"
            logger "802.11ac enabled: 80MHz channel, centre $RADIO_VHT_CENTER." 1
        else
            logger "Channel $RADIO_CHANNEL cannot form an 80MHz block; VHT stays at 40MHz." 1
        fi
    fi

    if [ -n "$COUNTRY_CODE" ] ; then
        logger "Add to $conf: country_code=$COUNTRY_CODE" 1
        echo "country_code=$COUNTRY_CODE"$'\n' >> "$conf"
        logger "Add to $conf: ieee80211d=1" 1
        echo "ieee80211d=1"$'\n' >> "$conf"
    fi

    if [ "$RADIO_IS_DFS" == "true" ] ; then
        logger "Add to $conf: ieee80211h=1" 1
        echo "ieee80211h=1"$'\n' >> "$conf"
        logger "DFS channel $RADIO_CHANNEL selected. hostapd will listen for radar for 60s or more before the AP becomes available." 0
    fi

    if [ "$BRIDGE_ENABLED" == "true" ] ; then
        logger "Add to $conf: bridge=$BRIDGE_NAME" 1
        echo "bridge=$BRIDGE_NAME"$'\n' >> "$conf"
    fi

    ## MAC filtering. Allow is more restrictive, so we prioritise that and set
    ## macaddr_acl to 1. The allow/deny files themselves are written once below.
    if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
        logger "Add to $conf: macaddr_acl=1" 1
        echo "macaddr_acl=1"$'\n' >> "$conf"
        logger "Add to $conf: accept_mac_file=/hostapd.allow" 1
        echo "accept_mac_file=/hostapd.allow"$'\n' >> "$conf"
    elif [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
        logger "Add to $conf: macaddr_acl=0" 1
        echo "macaddr_acl=0"$'\n' >> "$conf"
        logger "Add to $conf: deny_mac_file=/hostapd.deny" 1
        echo "deny_mac_file=/hostapd.deny"$'\n' >> "$conf"
    else
        logger "Add to $conf: macaddr_acl=0" 1
        echo "macaddr_acl=0"$'\n' >> "$conf"
    fi

    # Append override options to the hostapd config
    if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom hostapd config options:" 0
        HOSTAPD_OVERRIDES=($HOSTAPD_CONFIG_OVERRIDE)
        for override in "${HOSTAPD_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> "$conf"
            logger "Add to $conf: $override" 0
        done
    fi
}

### MAC address filtering
## The allow/deny file is written once; both radios reference the same file.
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
    ALLOWED=($ALLOW_MAC_ADDRESSES)
    logger "# Setup hostapd.allow:" 1
    logger "Allowed MAC addresses:" 0
    for mac in "${ALLOWED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.allow
        logger "$mac" 0
    done
elif [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
    DENIED=($DENY_MAC_ADDRESSES)
    logger "Denied MAC addresses:" 0
    for mac in "${DENIED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.deny
        logger "$mac" 0
    done
fi

if [ $DEBUG -ge 1 ] ; then
    case " ${RADIO_BANDS[*]} " in
        *" 5 "*) logger "# A 5GHz band is in use. Current regulatory domain:" 1
                 iw reg get 2>/dev/null || true ;;
    esac
    logger "# Channels reported by the drivers ('no IR' = cannot host an AP there):" 1
    iw phy 2>/dev/null | grep -E '^[[:space:]]*\*[[:space:]]*[0-9]+ MHz' | sed 's/^[[:space:]]*//' || true
fi

# Build one hostapd config per active band
RADIO_CONFS=()
for radio in "${!RADIO_IFACES[@]}" ; do
    conf="/hostapd$((radio + 1)).conf"
    write_hostapd_conf "${RADIO_IFACES[$radio]}" "${RADIO_BANDS[$radio]}" "$conf"
    RADIO_CONFS+=("$conf")
done


# Set address for the selected interface. Not sure why this is now not being set via /etc/network/interfaces, but maybe interfaces file is no longer required...
ifconfig $TARGET_INTERFACE $ADDRESS netmask $NETMASK broadcast $BROADCAST

# Setup dnsmasq.conf if DHCP is enabled in config
if $(bashio::config.true "general.dhcp"); then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$TARGET_INTERFACE" 1
        echo "interface=$TARGET_INTERFACE"$'\n' >> /dnsmasq.conf

    ## DNS
    dns_array=()
        if [ ${#CLIENT_DNS_OVERRIDE} -ge 1 ]; then
            dns_string="dhcp-option=6"
            DNS_OVERRIDES=($CLIENT_DNS_OVERRIDE)
            for override in "${DNS_OVERRIDES[@]}"; do
                dns_string+=",$override"
            done
            echo "$dns_string"$'\n' >> /dnsmasq.conf
            logger "Add custom DNS: $dns_string" 0
        else
            IFS=$'\n' read -r -d '' -a dns_array < <( nmcli device show | grep IP4.DNS | awk '{print $2}' && printf '\0' )

            if [ ${#dns_array[@]} -eq 0 ]; then
                logger "Couldn't get DNS servers from host. Consider setting with 'client_dns_override' config option." 0
            else
                dns_string="dhcp-option=6"
                for dns_entry in "${dns_array[@]}"; do
                    dns_string+=",$dns_entry"
                done
                echo "$dns_string"$'\n' >> /dnsmasq.conf
                logger "Add DNS: $dns_string" 0
            fi

        fi

    # Append override options to dnsmasq.conf
    if [ ${#DNSMASQ_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom dnsmasq config options:" 0
        DNSMASQ_OVERRIDES=($DNSMASQ_CONFIG_OVERRIDE)
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
    fi
else
	logger "# DHCP not enabled. Skipping dnsmasq" 1
	logger "DHCP is disabled, so clients will not be handed an IP address. Most phones and laptops then drop the connection and immediately reconnect, in a loop, just after the WPA handshake succeeds. Enable 'dhcp', or give the client a static address." 0
fi

is_masquerading_enabled() {
    iptables-nft -t nat -C POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet" 2>/dev/null
}

is_forwarding_enabled() {
    iptables-nft -C FORWARD -i $TARGET_INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet" 2>/dev/null
}

is_bridge_forwarding_enabled() {
    iptables-nft -C FORWARD -i $BRIDGE_NAME -o $BRIDGE_NAME -j ACCEPT -m comment --comment "ap-addon-bridge" 2>/dev/null
}

# Clients sitting on the two radios talk to each other through the bridge, so
# that traffic has to be allowed explicitly
if [ "$BRIDGE_ENABLED" == "true" ]; then
    if ! is_bridge_forwarding_enabled; then
        iptables-nft -A FORWARD -i $BRIDGE_NAME -o $BRIDGE_NAME -j ACCEPT -m comment --comment "ap-addon-bridge"
    fi
else
    if is_bridge_forwarding_enabled; then
        iptables-nft -D FORWARD -i $BRIDGE_NAME -o $BRIDGE_NAME -j ACCEPT -m comment --comment "ap-addon-bridge"
    fi
fi

# Setup Client Internet Access
if $(bashio::config.true "general.client_internet_access"); then
    ## Add masquerade if not already present
    if ! is_masquerading_enabled; then
        iptables-nft -t nat -A POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Allow forwarding if not already allowed
    if ! is_forwarding_enabled; then
        iptables-nft -A FORWARD -i $TARGET_INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -A FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $TARGET_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
else
    ## Remove masquerade if present
    if is_masquerading_enabled; then
        iptables-nft -t nat -D POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Remove forwarding if present
    if is_forwarding_enabled; then
        iptables-nft -D FORWARD -i $TARGET_INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -D FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $TARGET_INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
fi

# Start dnsmasq if DHCP is enabled in config
if $(bashio::config.true "general.dhcp"); then
    logger "## Starting dnsmasq daemon" 1
    if ! dnsmasq -C /dnsmasq.conf ; then
        logger "dnsmasq failed to start, so clients will not be handed an IP address and will keep reconnecting. Check that dhcp_start_addr/dhcp_end_addr are on the $ADDRESS/$NETMASK subnet." 0
    else
        logger "dnsmasq started, handing out $DHCP_START_ADDR to $DHCP_END_ADDR on $TARGET_INTERFACE" 1
    fi
fi

if [ $DEBUG -ge 1 ] ; then
    for conf in "${RADIO_CONFS[@]}" ; do
        echo "# Effective $conf:"
        sed 's/^wpa_passphrase=.*/wpa_passphrase=********/' "$conf"
    done
fi

# If debug level is greater than 1, start hostapd in debug mode
HOSTAPD_PIDS=()
for radio in "${!RADIO_IFACES[@]}" ; do
    logger "## Starting hostapd daemon for ${RADIO_IFACES[$radio]} (${RADIO_BANDS[$radio]} GHz)" 1
    if [ $DEBUG -gt 1 ]; then
        hostapd -d "${RADIO_CONFS[$radio]}" &
    else
        hostapd "${RADIO_CONFS[$radio]}" &
    fi
    HOSTAPD_PIDS+=("$!")
done

if [ ${#HOSTAPD_PIDS[@]} -gt 1 ] ; then
    # One radio failing takes the add-on down, rather than half-running
    wait -n "${HOSTAPD_PIDS[@]}"
    HOSTAPD_STATUS=$?
    for pid in "${HOSTAPD_PIDS[@]}" ; do
        kill "$pid" 2>/dev/null || true
    done
else
    wait "${HOSTAPD_PIDS[0]}"
    HOSTAPD_STATUS=$?
fi

if [ $HOSTAPD_STATUS -ne 0 ] ; then
    logger "hostapd exited with status $HOSTAPD_STATUS. Check the messages above: the usual causes are a DFS channel without radar support, a missing country_code, or an ht_capab/vht_capab flag the adapter does not support." 0
fi

exit $HOSTAPD_STATUS
