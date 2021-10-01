#!/bin/bash

# original script posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# Improved with suggestions from Threarah at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fv3cgi9/
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

while [ -n "$1" ]
do
	case "$1" in
		"-r")
			shift
			OPT_RECONNECT=1
			;;
		"-c")
			shift
			OPT_CONFIGONLY=1
			;;
		"-h")
			shift
			OPT_SHOWHELP=1
			;;
		*)
			echo "Unrecognized option: $1"
			shift
			OPT_SHOWHELP=1
			;;
	esac
done

if [ -n "$OPT_SHOWHELP" ]
then
	echo
	echo "USAGE: $(basename "$0") [-r] [-c]"
	echo
	echo "    -r  Force reconnection even if a cached link is available"
	echo
	echo "    -c  Config only - generate a WireGuard config but do not apply it to this system"
	echo
	exit 1
fi

if ! which curl &>/dev/null
then
	echo "The 'curl' utility is required"
	echo "    Most package managers should have a 'curl' package available"
	EXIT=1
fi

if ! which jq &>/dev/null
then
	echo "The 'jq' utility is required"
	echo "    Most package managers should have a 'jq' package available"
	EXIT=1
fi

if ! which wg &>/dev/null
then
	echo -n "The 'wg' utility from wireguard-tools is needed to generate keys"
	[ -z "$OPT_CONFIGONLY" ] && echo -n " and apply settings to this machine"
	echo
	echo "    Most package managers should have a 'wireguard-tools' package available"
	EXIT2=1
fi

if [ -z "$OPT_CONFIGONLY" ]
then
	if ! which ip &>/dev/null
	then
		echo "The 'ip' utility from iproute2 is needed to apply settings to this machine"
		echo "    Most package managers should have a 'iproute2' package available"
		EXIT2=1
	fi

	if [ -n "$EXIT2" ]
	then
		echo
		echo "You can use the -c option if you wish to only generate a config"
	fi
	EXIT="${EXIT}${EXIT2}"
else
	if ! which qrencode &>/dev/null
	then
		echo "The 'qrencode' utility is recommended if you want to generate a config for the WireGuard Android app"
		echo "    It will allow you to load the config easily by scanning a QR code printed to this terminal"
		echo "    A config will still be generated without it, but you will have to apply it by another method"
		# this is not an error, do not set EXIT
	fi
fi

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find 'pia-config.sh' at $PIA_CONFIG - please ensure it is present at that location, or suggest an improvement to this script for finding it"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

if ! [ -r "$CONFIG" ]
then
	echo "Cannot read '$CONFIG', generating a default one"
	if [ -z "$PIA_USERNAME" ]
	then
		read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
	fi
	cat <<ENDCONFIG > "$CONFIG"
# your privateinternetaccess.com username (not needed if you already have an auth token)
PIA_USERNAME="$PIA_USERNAME"

# [OPTIONAL] your privateinternetaccess.com password (only needed once for v2 tokens, will be requested when needed if absent here)
# PIA_PASSWORD=""

# your desired endpoint location
LOC="$LOC"

# the name of the network interface (default: pia)
# PIA_INTERFACE="$PIA_INTERFACE"

# wireguard client-side private key (new key generated every invocation if not specified)
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"

# if PORTFORWARD is set, pia-wg will only connect to port-forward capable servers, and will invoke pia-portforward.sh after connection
# PORTFORWARD="literally anything"

# If you have an existing routing table that only contains routes for hardware interfaces, specify it here
# this will allow pia-wg to hop endpoints without requiring you to disconnect first
# HARDWARE_ROUTE_TABLE="hardlinks"

# If you have daemons that you want to force to only use the VPN and already have a routing table for this purpose, specify it here
# pia-wg will add a default route via the PIA VPN link to that table for you
# VPNONLY_ROUTE_TABLE="vpnonly"
ENDCONFIG
	echo "Config saved"
fi

# fetch data-new.json if missing
if ! [ -r "$DATAFILE_NEW" ]
then
	echo "Fetching new generation server list from PIA"
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/new' -o "$DATAFILE_NEW.temp" || exit 1
	if [ "$(jq '.regions | map_values(select(.servers.wg)) | keys' "$DATAFILE_NEW.temp" 2>/dev/null | wc -l)" -le 30 ]
	then
		echo "Bad serverlist retrieved to $DATAFILE_NEW.temp, exiting"
		echo "You can try again if there was a transient error"
		exit 1
	else
		jq -cM '.' "$DATAFILE_NEW.temp" > "$DATAFILE_NEW" 2>/dev/null
	fi
fi

if ! [ -r "$PIA_CERT" ]
then
	echo "Fetching PIA self-signed RSA certificate from github"
	curl --max-time 15 'https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt' > "$PIA_CERT" || exit 1
fi

if [ -n "$OPT_RECONNECT" ]
then
	rm "$CONNCACHE" "$REMOTEINFO" 2>/dev/null
fi

if [ -r "$CONNCACHE" ]
then
	WG_NAME="$(jq -r ".name" "$CONNCACHE")"
	WG_DNS="$(jq -r ".dns"  "$CONNCACHE")"

	WG_HOST="$(jq -r ".servers.wg[0].ip"     "$CONNCACHE")"
	WG_CN="$(jq -r ".servers.wg[0].cn"     "$CONNCACHE")"
	WG_PORT="$(jq -r '.groups.wg[0].ports[]' "$DATAFILE_NEW" | sort -r | head -n1)"

	WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
fi

if [ -z "$WG_HOST" ] || [ -z "$WG_CN" ] || [ -z "$WG_PORT" ]
then
	if [ "$(jq -r ".regions | .[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")" == "" ]
	then
		LOC=$(jq -r '.regions | .[] | select(.id | test("^'"$LOC"'")) '${PORTFORWARD:+'| select(.port_forward) '}'| .id' "$DATAFILE_NEW" | shuf -n 1)
	fi

	if [ "$(jq -r ".regions | .[] | select(.id == \"$LOC\")" "$DATAFILE_NEW")" == "" ]
	then
		echo "Location $LOC not found!"
		echo "Options are:"
	# 	jq '.regions | .[] | .id' "$DATAFILE_NEW" | sort | sed -e 's/^/ * /'
		(
			echo "${BOLD}Location${TAB}Region${TAB}Port Forward${TAB}Geolocated${NORMAL}"
			echo "----------------${TAB}------------------${TAB}------------${TAB}----------"
			jq -r '.regions | .[] | '${PORTFORWARD:+'| select(.port_forward)'}' [.id, .name, .port_forward, .geo] | "'$'\e''[1m\(.[0])'$'\e''[0m\t\(.[1])\t\(.[2])\t\(.[3])"' "$DATAFILE_NEW"
		) | column -t -s "${TAB}"
		echo "${PORTFORWARD:+'Note: only port-forwarding regions displayed'}"
		echo "Please edit $CONFIG and change your desired location, then try again"
		exit 1
	fi

	jq -r ".regions | .[] | select(.id == \"$LOC\")" "$DATAFILE_NEW" > "$CONNCACHE"

	WG_NAME="$(jq -r ".name" "$CONNCACHE")"
	WG_DNS="$(jq -r ".dns"  "$CONNCACHE")"

	WG_HOST="$(jq -r ".servers.wg[0].ip"     "$CONNCACHE")"
	WG_CN="$(jq -r ".servers.wg[0].cn"     "$CONNCACHE")"
	WG_PORT="$(jq -r '.groups.wg[0].ports[]' "$DATAFILE_NEW" | sort -r | head -n1)"

	WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
fi

if [ -z "$WG_HOST$WG_PORT" ]; then
  echo "wg host/port not found (bad server list?), exiting"
  exit 1
fi

if ! [ -r "$REMOTEINFO" ]
then
	if [ -z "$TOK" ]
	then
		PASS="$PIA_PASSWORD"
		if [ -z "$PIA_USERNAME" ] || [ -z "$PASS" ]
		then
			echo "A new auth token is required."
		fi
		if [ -z "$PIA_USERNAME" ]
		then
			read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
			[ -z "$PIA_USERNAME" ] && exit 1
		fi
		if [ -z "$PASS" ]
		then
			echo "Your password will NOT be saved."
			read -p "Please enter your privateinternetaccess.com password for $PIA_USERNAME: " -s PASS
			[ -z "$PASS" ] && exit 1
		fi
		TOK=$(curl -X POST \
			-H "Content-Type: application/json" \
			-d "{\"username\":\"$PIA_USERNAME\",\"password\":\"$PASS\"}" \
			"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')
		if [ -z "$TOK" ]
		then
			echo "failed, trying meta server"
			METASERVER="$(jq -r ".servers.meta[0].ip" "$CONNCACHE")"
			METADNS="$(jq -r ".servers.meta[0].cn" "$CONNCACHE")"
			TOK=$(curl -s \
				--cacert "$PIA_CERT" \
				--resolve "$METADNS:443:$METASERVER" \
				-u "$PIA_USERNAME:$PASS" \
				"https://$METADNS/authv3/generateToken" \
				| jq -r ".token")
		fi
		if [ -z "$TOK" ]
		then
			echo "PIA API v2 failed, trying V3"
			TOK=$(curl -s -u "$PIA_USERNAME:$PASS" \
				"https://privateinternetaccess.com/gtoken/generateToken" | jq -r '.token')
		fi

		if [ -z "$PIA_PASSWORD" ]
		then
			unset PASS
			echo "Your password has been forgotten, please edit $CONFIG and set PIA_PASSWORD if you wish to store it permanently."
		fi

		# echo "got token: $TOK"

		if [ -z "$TOK" ]; then
			echo "Failed to authenticate with privateinternetaccess"
			echo "Check your user/pass and try again"
			exit 1
		fi

		touch "$TOKENFILE"
		chmod 600 "$TOKENFILE"
		echo "$TOK" > "$TOKENFILE"

		echo "Functional DNS is no longer required."
		echo "If you're setting up in a region with heavy internet restrictions, you can disable your alternate VPN or connection method now"
	fi

	echo "Registering public key with ${BOLD}$WG_NAME $WG_HOST${NORMAL}"
	[ "$EUID" -eq 0 ] && [ -z "$OPT_CONFIGONLY" ] && ip rule add to "$WG_HOST" lookup china pref 10

	if ! curl -GsS \
		--max-time 5 \
		--data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
		--data-urlencode "pt=$TOK" \
		--cacert "$PIA_CERT" \
		--resolve "$WG_CN:$WG_PORT:$WG_HOST" \
		"https://$WG_CN:$WG_PORT/addKey" > "$REMOTEINFO.temp"
	then
		echo "Registering with $WG_CN failed, trying $WG_DNS"
		# fall back to trying DNS certificate if CN fails
		# /u/dean_oz reported that this works better for them at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fyfqjf7/
		# in testing I find that sometimes one works, sometimes the other works
		if ! curl -GsS \
			--max-time 5 \
			--data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
			--data-urlencode "pt=$TOK" \
			--cacert "$PIA_CERT" \
			--resolve "$WG_DNS:$WG_PORT:$WG_HOST" \
			"https://$WG_DNS:$WG_PORT/addKey" > "$REMOTEINFO.temp"
		then
			echo "Failed to register key with $WG_SN ($WG_HOST)"
			if ! [ -e "/sys/class/net/$PIA_INTERFACE" ]
			then
				echo "If you're trying to change hosts because your link has stopped working,"
				echo "  you may need to ${BOLD}ip link del dev $PIA_INTERFACE${NORMAL} and try this script again"
			fi
			rm -f "$CONNCACHE" "$REMOTEINFO"
			exit 1
		fi
	fi

	if [ "$(jq -r .status "$REMOTEINFO.temp")" != "OK" ]
	then
		echo "WG key registration failed - bad token?"
		jq "$REMOTEINFO.temp"
		echo "If you see an auth error, consider deleting $TOKENFILE and getting a new token"
		exit 1
	fi

	mv  "$REMOTEINFO.temp" \
		"$REMOTEINFO"
fi

PEER_IP="$(jq -r .peer_ip "$REMOTEINFO")"
SERVER_PUBLIC_KEY="$(jq -r .server_key  "$REMOTEINFO")"
SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"
SERVER_PORT="$(jq -r .server_port "$REMOTEINFO")"
SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

if [ -n "$OPT_CONFIGONLY" ]
then
	cat > "$WGCONF" <<ENDWG
	[Interface]
	PrivateKey = $CLIENT_PRIVATE_KEY
	Address    = $PEER_IP
	DNS        = $(jq -r '.dns_servers[0:2]' "$REMOTEINFO" | grep ^\  | cut -d\" -f2 | xargs echo | sed -e 's/ /,/g')

	[Peer]
	PublicKey  = $SERVER_PUBLIC_KEY
	AllowedIPs = 0.0.0.0/0, ::/0
	Endpoint   = $SERVER_IP:$SERVER_PORT
ENDWG

	echo
	echo "$WGCONF generated:"
	echo
	cat "$WGCONF"
	echo
	if which qrencode &>/dev/null
	then
		qrencode -t ansiutf8 < "$WGCONF"
	fi
	echo
	exit 0
fi

if ! ip route show table "$HARDWARE_ROUTE_TABLE" 2>/dev/null | grep -q .
then
	ROUTES_ADD=$(
		for IF in $(ip link show | grep -B1 'link/ether' | grep '^[0-9]' | cut -d: -f2)
		do
			ip route show | grep "dev $IF" | sed -e 's/linkdown//' | sed -e "s/^/ip route add table $HARDWARE_ROUTE_TABLE /"
		done
	)
	if [ "$EUID" -eq 0 ]
	then
		echo "Build a routing table with only hardware links to stop wireguard packets going back through the VPN:"
		echo sudo sh '<<<' "$ROUTES_ADD"
		sudo sh <<< "$ROUTES_ADD"
	else
		sh <<< "$ROUTES_ADD"
	fi
	echo "Table $HARDWARE_ROUTE_TABLE (hardware network links) now contains:"
	ip route show table $HARDWARE_ROUTE_TABLE | sed -e "s/^/${TAB}/"
	echo
	echo "${BOLD}*** PLEASE NOTE: if this table isn't updated by your network post-connect hooks, your connection cannot remain up if your network links change${NORMAL}"
	echo "Managing such hooks is beyond the scope of this script"
fi

# echo "Bringing up wireguard interface $PIA_INTERFACE... "
if [ "$EUID" -eq 0 ]
then
	# scratch current config if any
	# put new settings into existing interface instead of teardown/re-up to prevent leaks
	if ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo "Updating existing interface '$PIA_INTERFACE'"

		OLD_PEER_IP="$(ip -j addr show dev pia | jq -r '.[].addr_info[].local')"
		OLD_KEY="$(echo $(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2-))"
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut "-d${TAB}" -f2 | cut -d: -f1)"

		# Note: unnecessary if Table != off above, but doesn't hurt.
		# ensure we don't get a packet storm loop
		ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10

		if [ "$OLD_KEY" != "$SERVER_PUBLIC_KEY" ]
		then
			echo "    [Change Peer from $OLD_KEY to $SERVER_PUBLIC_KEY]"
			wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
			# remove old key
			wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
		fi

		if [ "$PEER_IP" != "$OLD_PEER_IP/32" ]
		then
			echo "    [Change $PIA_INTERFACE ipaddr from $OLD_PEER_IP to $PEER_IP]"
			# update link ip address in case
			ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
			ip addr del "$OLD_PEER_IP/32" dev "$PIA_INTERFACE"

			# remove old route
			ip rule del to "$OLD_PEER_IP" lookup $HARDWARE_ROUTE_TABLE 2>/dev/null
		fi

		# Note: only if Table = off in wireguard config file above
		ip route add default dev "$PIA_INTERFACE"

		# Specific to my setup
		ip route add default table $VPNONLY_ROUTE_TABLE dev "$PIA_INTERFACE"
	else
		echo "Bringing up interface '$PIA_INTERFACE'"

		# Note: unnecessary if Table != off above, but doesn't hurt.
		ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10

		# bring up wireguard interface
		ip link add "$PIA_INTERFACE" type wireguard || exit 1
		ip link set dev "$PIA_INTERFACE" up || exit 1
		wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
		ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" || exit 1

		# Note: only if Table = off in wireguard config file above
		ip route add default dev "$PIA_INTERFACE"

		# Specific to my setup
		ip route add default table $VPNONLY_ROUTE_TABLE dev "$PIA_INTERFACE"

	fi
else
	echo
	echo "Not running as root/sudo - did you want to specify -c (config only) ?"
	echo "Setup commands will now be fed through sudo"
	echo
	echo ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10
	sudo ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10 || exit 1

	if ! ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo ip link add "$PIA_INTERFACE" type wireguard
		sudo ip link add "$PIA_INTERFACE" type wireguard || exit 1
	fi

	echo wg set "$PIA_INTERFACE" fwmark 51820 private-key "$CLIENT_PRIVATE_KEY"         peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0"
	sudo wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1

	echo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
	sudo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" || exit 1

	if ip link list "$PIA_INTERFACE" > /dev/null
	then
		OLD_PEER_IP="$(ip -j addr show dev pia | jq '.[].addr_info[].local')"
		OLD_KEY="$(echo $(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2))"
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut "-d${TAB}" -f2 | cut -d: -f1)"

		echo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
		sudo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove || exit 1
	fi

	echo ip route add default dev "$PIA_INTERFACE"
	sudo ip route add default dev "$PIA_INTERFACE" || exit 1
fi

echo "PIA Wireguard '$PIA_INTERFACE' configured successfully"

TRIES=0
echo -n "Waiting for connection to stabilise..."
while ! ping -n -c1 -w 1 -s 1280 -I "$PIA_INTERFACE" "$SERVER_VIP" &>/dev/null
do
	echo -n "."
	TRIES=$(( $TRIES + 1 ))
	if [[ $TRIES -ge 5 ]]
	then
		echo "Connection failed to stabilise, try again"
		rm -f "$CONNCACHE" "$REMOTEINFO"
		exit 1
	fi
	sleep 0.5 # so we can catch ctrl+c
done
echo " OK"

if find "$DATAFILE_NEW" -mtime -3 -exec false {} +
then
	echo "PIA endpoint list is stale, Fetching new generation wireguard server list"

	echo curl --max-time 15 --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v4"
	curl --max-time 15 --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v4" > "$DATAFILE_NEW.temp" || \
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/new' > "$DATAFILE_NEW.temp" || exit 0

	if [ "$(jq '.regions | map_values(select(.servers.wg)) | keys' "$DATAFILE_NEW.temp" 2>/dev/null | wc -l)" -le 30 ]
	then
		echo "Bad serverlist retrieved to $DATAFILE_NEW.temp, exiting"
		echo "You can try again if there was a transient error"
		# exit 1 // this isn't a fatal error, just an inconvenience
	else
		jq -cM '.' "$DATAFILE_NEW.temp" > "$DATAFILE_NEW" 2>/dev/null
	fi
fi

if [ -n "$PORTFORWARD" ]
then
	echo "Requesting forwarded port..."
	if which pia-portforward.sh &>/dev/null
	then
		pia-portforward.sh
	else
		if [ -e "${0%/*}/pia-portforward.sh" ]
		then
			"${0%/*}/pia-portforward.sh"
		else
			PIA_PORTFORWARD="$(dirname "$(realpath "$(which "$0")")")/pia-portforward.sh"
			if [ -e "$PIA_PORTFORWARD" ]
			then
				"$PIA_PORTFORWARD"
			else
				echo "pia-portforward.sh couldn't be found!"
				exit 1
			fi
		fi
	fi
	echo "Note: pia-portforward.sh should be called every ~5 minutes to maintain your forward."
	echo "You could try:"
	echo "    while sleep 5m; do pia-portforward.sh; done"
	echo "or alternately add a cronjob with crontab -e"
fi

exit 0
