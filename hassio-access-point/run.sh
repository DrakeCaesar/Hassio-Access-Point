#!/usr/bin/with-contenv bashio

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
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

# Read an optional config value, as an empty string when unset.
# bashio::config falls back to the literal string "null" for options left blank
# (its default parameter is "null", and an empty default counts as unset), and
# returns "false" for false booleans. Normalise both to an empty string.
optional_config(){
    local value
    value=$(bashio::config "$1")
    case "$value" in
        null|false) echo "" ;;
        *) echo "$value" ;;
    esac
}

CONFIG_PATH=/data/options.json

# Convert integer configs to boolean, to avoid a breaking old configs
declare -r bool_configs=( hide_ssid client_internet_access dhcp )
for i in $bool_configs ; do
    if bashio::config.true $i || bashio::config.false $i ; then
        continue
    elif [ $config_value -eq 0 ] ; then
        bashio::addon.option $config_value false
    else
        bashio::addon.option $config_value true
    fi
done

SSID=$(bashio::config "ssid")
WPA_PASSPHRASE=$(bashio::config "wpa_passphrase")
CHANNEL=$(bashio::config "channel")
ADDRESS=$(bashio::config "address")
NETMASK=$(bashio::config "netmask")
BROADCAST=$(bashio::config "broadcast")
INTERFACE=$(bashio::config "interface")
HIDE_SSID=$(bashio::config.false "hide_ssid"; echo $?)
DHCP=$(bashio::config.false "dhcp"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr" )
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr" )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )
ALLOW_MAC_ADDRESSES=$(bashio::config 'allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'deny_mac_addresses' )
DEBUG=$(bashio::config 'debug' )
BAND=$(bashio::config 'band' '2.4')
COUNTRY_CODE=$(optional_config 'country_code')
HT_CAPAB=$(optional_config 'ht_capab')
VHT_CAPAB=$(optional_config 'vht_capab')
DFS=$(bashio::config 'dfs' 'false')
HOSTAPD_CONFIG_OVERRIDE=$(bashio::config 'hostapd_config_override' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'client_dns_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )

# Get the Default Route interface
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5 }')

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces

logger "Run command: nmcli dev set $INTERFACE managed no" 1
nmcli dev set $INTERFACE managed no

logger "Run command: ip link set $INTERFACE down" 1
ip link set $INTERFACE down

logger "Add to /etc/network/interfaces: address $ADDRESS" 1
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: broadcast $BROADCAST" 1
echo "broadcast $BROADCAST"$'\n' >> /etc/network/interfaces

logger "Run command: ip link set $INTERFACE up" 1
ip link set $INTERFACE up

# Setup signal handlers
trap 'term_handler' SIGTERM

# Enforces required env variables
required_vars=(ssid wpa_passphrase channel address netmask broadcast)
for required_var in "${required_vars[@]}"; do
    bashio::config.require $required_var "An AP cannot be created without this information"
done

if [ ${#WPA_PASSPHRASE} -lt 8 ] ; then
    bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

# Determine the hardware mode from the selected band and validate the channel.
# 2.4GHz -> hw_mode=g, 5GHz -> hw_mode=a.
if [ "$BAND" == "5" ] ; then
    HW_MODE=a
    if [ "$CHANNEL" -lt 36 ] || [ "$CHANNEL" -gt 177 ] ; then
        bashio::exit.nok "Channel $CHANNEL is not valid for the 5GHz band. Use 36, 40, 44 or 48 (non-DFS), or 149-165 where your region allows it."
    fi
    # HT40+ puts the 40MHz secondary channel above the primary, so it is not usable
    # on the top channel of a block (48 -> 52 and 165 -> 169 are out of range).
    if [ "$CHANNEL" -eq 48 ] || [ "$CHANNEL" -eq 165 ] ; then
        HT40_MODE=HT40-
    else
        HT40_MODE=HT40+
    fi
    # [DSSS_CCK-40] is a 2.4GHz-only capability and must NOT be used on 5GHz.
    DEFAULT_HT_CAPAB="[$HT40_MODE][SHORT-GI-20][SHORT-GI-40]"
    # Channels 52-144 are DFS: they must listen for radar (CAC) before they are
    # allowed to transmit, which takes 60s to 10 minutes and needs hardware support.
    if [ "$CHANNEL" -ge 52 ] && [ "$CHANNEL" -le 144 ] ; then
        IS_DFS=true
    else
        IS_DFS=false
    fi
else
    HW_MODE=g
    IS_DFS=false
    DEFAULT_HT_CAPAB="[HT40][SHORT-GI-20][DSSS_CCK-40]"
    if [ "$CHANNEL" -gt 13 ] ; then
        bashio::exit.nok "Channel $CHANNEL is not valid for the 2.4GHz band. Use a channel between 1 and 13."
    fi
fi

# DFS channels are opt-in: without ieee80211h hostapd refuses them as "NO-IR RADAR",
# which is what the cryptic "Could not select hw_mode and channel. (-3)" message means.
if [ "$IS_DFS" == "true" ] ; then
    if [ "$DFS" != "true" ] ; then
        bashio::exit.nok "Channel $CHANNEL is a DFS channel (52-144). It must listen for radar before it may transmit, and the built-in Raspberry Pi radio cannot do that. Use a non-DFS channel such as 36, 40, 44 or 48 (or 149-165 where your region allows it), or set 'dfs' to true if your adapter supports radar detection."
    fi
    if [ -z "$COUNTRY_CODE" ] ; then
        bashio::exit.nok "DFS channel $CHANNEL needs a regulatory domain. Set 'country_code' to your two-letter country code."
    fi
fi

# The Supervisor cannot express "optional match" schema types: an empty string has
# to be the "use the default" sentinel because a value of null is rejected for any
# key present in `options`, optional or not. Validate the flag lists here instead.
FLAG_LIST_REGEX='^(\[[A-Z0-9][A-Z0-9_+-]*\])+$'
if [ -n "$HT_CAPAB" ] && ! [[ "$HT_CAPAB" =~ $FLAG_LIST_REGEX ]] ; then
    bashio::exit.nok "ht_capab must be a list of flags in square brackets, e.g. '[HT40][SHORT-GI-20]'. Got: $HT_CAPAB"
fi
if [ -n "$VHT_CAPAB" ] && ! [[ "$VHT_CAPAB" =~ $FLAG_LIST_REGEX ]] ; then
    bashio::exit.nok "vht_capab must be a list of flags in square brackets, e.g. '[SHORT-GI-80]'. Got: $VHT_CAPAB"
fi
if [ -n "$COUNTRY_CODE" ] && ! [[ "$COUNTRY_CODE" =~ ^[A-Z]{2}$ ]] ; then
    bashio::exit.nok "country_code must be a two-letter uppercase country code, e.g. 'GB'. Got: $COUNTRY_CODE"
fi

# Fall back to a band-appropriate set of HT capabilities
if [ -z "$HT_CAPAB" ] ; then
    HT_CAPAB=$DEFAULT_HT_CAPAB
fi

# Setup hostapd.conf
logger "# Setup hostapd:" 1
logger "Add to hostapd.conf: ssid=$SSID" 1
echo "ssid=$SSID"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: wpa_passphrase=********" 1
echo "wpa_passphrase=$WPA_PASSPHRASE"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: hw_mode=$HW_MODE (band $BAND GHz)" 1
echo "hw_mode=$HW_MODE"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: channel=$CHANNEL" 1
echo "channel=$CHANNEL"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ignore_broadcast_ssid=$HIDE_SSID" 1
echo "ignore_broadcast_ssid=$HIDE_SSID"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ieee80211n=1" 1
echo "ieee80211n=1"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ht_capab=$HT_CAPAB" 1
echo "ht_capab=$HT_CAPAB"$'\n' >> /hostapd.conf

# 802.11ac (VHT) is optional and only meaningful on the 5GHz band. It must not
# be enabled for adapters that don't support it, or hostapd will refuse to start.
if [ "$BAND" == "5" ] && $(bashio::config.true 'ieee80211ac') ; then
    logger "Add to hostapd.conf: ieee80211ac=1" 1
    echo "ieee80211ac=1"$'\n' >> /hostapd.conf
    if [ -n "$VHT_CAPAB" ] ; then
        logger "Add to hostapd.conf: vht_capab=$VHT_CAPAB" 1
        echo "vht_capab=$VHT_CAPAB"$'\n' >> /hostapd.conf
    fi
fi

# A country code enables the regulatory domain, which is required for many
# 5GHz channels (especially the DFS ones) to be usable.
if [ -n "$COUNTRY_CODE" ] ; then
    logger "Add to hostapd.conf: country_code=$COUNTRY_CODE" 1
    echo "country_code=$COUNTRY_CODE"$'\n' >> /hostapd.conf
    logger "Add to hostapd.conf: ieee80211d=1" 1
    echo "ieee80211d=1"$'\n' >> /hostapd.conf
fi

# Enable DFS radar detection (CAC). Only meaningful together with a DFS channel,
# and hostapd refuses ieee80211h without a country_code.
if [ "$IS_DFS" == "true" ] ; then
    logger "Add to hostapd.conf: ieee80211h=1" 1
    echo "ieee80211h=1"$'\n' >> /hostapd.conf
    logger "DFS channel $CHANNEL selected. hostapd will listen for radar for 60s or more before the AP becomes available." 0
fi

# Helpful when a 5GHz AP refuses to start: dual-band radios (e.g. the built-in
# Raspberry Pi 3B+/4/5 wireless) will not come up on 5GHz until a regulatory
# domain is known.
if [ "$BAND" == "5" ] && [ $DEBUG -ge 1 ] ; then
    logger "# 5GHz band selected. Current regulatory domain:" 1
    iw reg get 2>/dev/null || true
fi

### MAC address filtering
## Allow is more restrictive, so we prioritise that and set
## macaddr_acl to 1, and add allowed MAC addresses to hostapd.allow
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
    logger "Add to hostapd.conf: macaddr_acl=1" 1
    echo "macaddr_acl=1"$'\n' >> /hostapd.conf
    ALLOWED=($ALLOW_MAC_ADDRESSES)
    logger "# Setup hostapd.allow:" 1
    logger "Allowed MAC addresses:" 0
    for mac in "${ALLOWED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.allow
        logger "$mac" 0
    done
    logger "Add to hostapd.conf: accept_mac_file=/hostapd.allow" 1
    echo "accept_mac_file=/hostapd.allow"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, and add denied MAC addresses to hostapd.deny
elif [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
        logger "Add to hostapd.conf: macaddr_acl=0" 1
        echo "macaddr_acl=0"$'\n' >> /hostapd.conf
        DENIED=($DENY_MAC_ADDRESSES)
        logger "Denied MAC addresses:" 0
        for mac in "${DENIED[@]}"; do
            echo "$mac"$'\n' >> /hostapd.deny
            logger "$mac" 0
        done
        logger "Add to hostapd.conf: accept_mac_file=/hostapd.deny" 1
        echo "deny_mac_file=/hostapd.deny"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, with blank allow and deny files
else
    logger "Add to hostapd.conf: macaddr_acl=0" 1
    echo "macaddr_acl=0"$'\n' >> /hostapd.conf
fi


# Set address for the selected interface. Not sure why this is now not being set via /etc/network/interfaces, but maybe interfaces file is no longer required...
ifconfig $INTERFACE $ADDRESS netmask $NETMASK broadcast $BROADCAST

# Add interface to hostapd.conf
logger "Add to hostapd.conf: interface=$INTERFACE" 1
echo "interface=$INTERFACE"$'\n' >> /hostapd.conf

# Append override options to hostapd.conf
if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
    logger "# Custom hostapd config options:" 0
    HOSTAPD_OVERRIDES=($HOSTAPD_CONFIG_OVERRIDE)
    for override in "${HOSTAPD_OVERRIDES[@]}"; do
        echo "$override"$'\n' >> /hostapd.conf
        logger "Add to hostapd.conf: $override" 0
    done
fi

# Setup dnsmasq.conf if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf

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
    iptables-nft -C FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet" 2>/dev/null
}

# Setup Client Internet Access
if $(bashio::config.true "client_internet_access"); then
    ## Add masquerade if not already present
    if ! is_masquerading_enabled; then
        iptables-nft -t nat -A POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Allow forwarding if not already allowed
    if ! is_forwarding_enabled; then
        iptables-nft -A FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -A FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
else
    ## Remove masquerade if present
    if is_masquerading_enabled; then
        iptables-nft -t nat -D POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Remove forwarding if present
    if is_forwarding_enabled; then
        iptables-nft -D FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -D FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
fi

# Start dnsmasq if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "## Starting dnsmasq daemon" 1
    if ! dnsmasq -C /dnsmasq.conf ; then
        logger "dnsmasq failed to start, so clients will not be handed an IP address and will keep reconnecting. Check that dhcp_start_addr/dhcp_end_addr are on the $ADDRESS/$NETMASK subnet." 0
    else
        logger "dnsmasq started, handing out $DHCP_START_ADDR to $DHCP_END_ADDR on $INTERFACE" 1
    fi
fi

# Dump the configuration we ended up with. Most "client cannot connect" reports are
# far easier to diagnose from this than from the option values.
if [ $DEBUG -ge 1 ] ; then
    echo "# Effective /hostapd.conf:"
    sed 's/^wpa_passphrase=.*/wpa_passphrase=********/' /hostapd.conf
fi

logger "## Starting hostapd daemon" 1
# If debug level is greater than 1, start hostapd in debug mode
if [ $DEBUG -gt 1 ]; then
    hostapd -d /hostapd.conf &
else
    hostapd /hostapd.conf &
fi
HOSTAPD_PID=$!
wait "$HOSTAPD_PID"
HOSTAPD_STATUS=$?

if [ $HOSTAPD_STATUS -ne 0 ] ; then
    logger "hostapd exited with status $HOSTAPD_STATUS. Check the messages above: the usual causes are a DFS channel without radar support, a missing country_code, or an ht_capab/vht_capab flag the adapter does not support." 0
fi

exit $HOSTAPD_STATUS
