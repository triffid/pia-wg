#!/bin/bash

# original script posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# Improved with suggestions from Threarah at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fv3cgi9/
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

if ! which jq &>/dev/null
then
	echo "The 'jq' utility is required"
	echo "    Most package managers should have a 'jq' package available"
	EXIT=1
fi

if ! which ip &>/dev/null
then
	echo "The 'ip' utility from iproute2 is required"
	echo "    Most package managers should have a 'iproute2' package available"
	EXIT=1
fi

if ! which curl &>/dev/null
then
	echo "The 'curl' utility is required"
	echo "    Most package managers should have a 'curl' package available"
	EXIT=1
fi

if ! which wg &>/dev/null
then
	echo "The 'wg' utility from wireguard-tools is required"
	echo "    Most package managers should have a 'wireguard-tools' package available"
	EXIT=1
fi

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG - if you've symlinked pia-wg.sh, please also symlink that file"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

if [ -z "$TOK" ] && ([ -z "$PIA_USERNAME" ] || [ -z "$PASS" ])
then
	if [ -z "$PIA_USERNAME" ]
	then
		read -p "Please enter your privateinternetaccess.com username: " PIA_USERNAME
	fi
	if [ -z "$PASS" ]
	then
		echo "If you do not wish to save your password, and want to be asked every time an auth token is required, simply press enter now"
		read -p "Please enter your privateinternetaccess.com password: " -s PASS
	fi
	cat <<ENDCONFIG > "$CONFIG"
# your privateinternetaccess.com username (not needed if you already have an auth token)
PIA_USERNAME="$PIA_USERNAME"
# your privateinternetaccess.com password (not needed if you already have an auth token)
PASS='$PASS'

# your desired endpoint location
LOC="$LOC"

# the name of the network interface (default: pia)
# PIA_INTERFACE="$PIA_INTERFACE"

# wireguard client-side private key (new key generated every invocation if not specified)
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"

# if PORTFORWARD is set, pia-wg will only connect to port-forward capable servers, and will invoke pia-portforward.sh after connection
# PORTFORWARD="literally anything"

ENDCONFIG
	echo "Config saved"
fi

# fetch data.json if missing
# if ! [ -r "$DATAFILE" ]
# then
# 	echo "Fetching wireguard server list from PIA"
# 	# wget -O "$DATAFILE" 'https://raw.githubusercontent.com/pia-foss/desktop/master/tests/res/openssl/payload1/payload' || exit 1
# 	curl 'https://www.privateinternetaccess.com/vpninfo/servers?version=1001&client=x-alpha' > "$DATAFILE.temp" || exit 1
# 	if [ "$(jq 'map_values(select(.wireguard)) | keys' "$DATAFILE.temp" 2>/dev/null | wc -l)" -le 50 ]
# 	then
# 		echo "Bad serverlist retrieved to $DATAFILE.temp, exiting"
# 		echo "You can try again if there was a transient error"
# 		exit 1
# 	else
# 		jq -cM 'map_values(select(.wireguard))' "$DATAFILE.temp" > "$DATAFILE" 2>/dev/null
# 	fi
# fi

# fetch data-new.json if missing
if ! [ -r "$DATAFILE_NEW" ]
then
	echo "Fetching new generation server list from PIA"
	# wget -O "$DATAFILE" 'https://raw.githubusercontent.com/pia-foss/desktop/master/tests/res/openssl/payload1/payload' || exit 1
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
	echo "Fetching PIA self-signed cert from github"
	curl --max-time 15 'https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt' > "$PIA_CERT" || exit 1
fi

if [ "$1" == "-n" ]
then
	rm "$CONNCACHE"
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
		( echo $'\e[1mLocation\e[1m\tRegion\tPort Forward\tGeolocated'; echo $'\e[0m----------------\e[0m\t------------------\t------------\t----------'; jq -r '.regions | .[] | '${PORTFORWARD:+'| select(.port_forward)'}' [.id, .name, .port_forward, .geo] | "'$'\e''[1m\(.[0])'$'\e''[0m\t\(.[1])\t\(.[2])\t\(.[3])"' "$DATAFILE_NEW"; ) | column -t -s $'\t'
		echo "${PORTFORWARD:+'Note: only port-forwarding regions displayed'}"
		echo "Please edit $CONFIG and change your desired location, then try again"
		exit 1
	fi

	if [ -z "$TOK" ]
	then
		if [ -z "$PASS" ]
		then
			echo "A new auth token is required, and you have not saved your password."
			echo "Your password will NOT be saved if you enter it now."
			read -p "Please enter your privateinternetaccess.com password for $PIA_USERNAME: " -s PASS
		fi
		TOK=$(curl -X POST \
		-H "Content-Type: application/json" \
		-d "{\"username\":\"$PIA_USERNAME\",\"password\":\"$PASS\"}" \
		"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')

		# echo "got token: $TOK"

		if [ -z "$TOK" ]; then
			echo "Failed to authenticate with privateinternetaccess"
			echo "Check your user/pass and try again"
			exit 1
		fi

		touch "$TOKENFILE"
		chmod 600 "$TOKENFILE"
		echo "$TOK" > "$TOKENFILE"
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
  echo "no wg region, exiting"
  exit 1
fi

echo "Registering public key with "$'\e[1m'"$WG_NAME"$'\e[0m (\e[1m'"$WG_HOST"$'\e[0m)'
ip rule add to "$WG_HOST" lookup china pref 10

if ! curl -GsS \
  --max-time 5 \
  --data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
  --data-urlencode "pt=$TOK" \
  --cacert "$PIA_CERT" \
  --resolve "$WG_DNS:$WG_PORT:$WG_HOST" \
  "https://$WG_DNS:$WG_PORT/addKey" > "$REMOTEINFO.temp"
then
	echo "Registering with $WG_DNS failed, trying $WG_CN"
	# fall back to trying 'cn' certificate if DNS fails
	# /u/dean_oz reported that this works better for them at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fyfqjf7/
	# in testing I find that sometimes one works, sometimes the other works
	if ! curl -GsS \
	  --max-time 5 \
	  --data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
	  --data-urlencode "pt=$TOK" \
	  --cacert "$PIA_CERT" \
	  --resolve "$WG_CN:$WG_PORT:$WG_HOST" \
	  "https://$WG_CN:$WG_PORT/addKey" > "$REMOTEINFO.temp"
	then
		echo "Failed to register key with $WG_SN ($WG_HOST)"
		if ! [ -e "/sys/class/net/$PIA_INTERFACE" ]
		then
			echo "If you're trying to change hosts because your link has stopped working,"
			echo "  you may need to "$'\x1b[1m'"ip link del dev $PIA_INTERFACE"$'\x1b[0m'" and try this script again"
		fi
		exit 1
	fi
fi

if [ "$(jq -r .status "$REMOTEINFO.temp")" != "OK" ]
then
	echo "WG key registration failed - bad token?"
	echo "If you see an auth error, consider deleting $TOKENFILE and getting a new token"
	exit 1
fi

mv  "$REMOTEINFO.temp" \
	"$REMOTEINFO"

PEER_IP="$(jq -r .peer_ip "$REMOTEINFO")"
SERVER_PUBLIC_KEY="$(jq -r .server_key  "$REMOTEINFO")"
SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"
SERVER_PORT="$(jq -r .server_port "$REMOTEINFO")"
SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

# echo "Generating $WGCONF"
# echo

# cat > "$WGCONF" <<ENDWG
# [Interface]
# PrivateKey = $CLIENT_PRIVATE_KEY
# Address    = $PEER_IP
# Table      = off
# DNS        = $(jq -r '.dns_servers[0:2]' "$REMOTEINFO" | grep ^\  | cut -d\" -f2 | xargs echo | sed -e 's/ /,/g')
#
# [Peer]
# PublicKey  = $SERVER_PUBLIC_KEY
# AllowedIPs = 0.0.0.0/0, ::/0
# Endpoint   = $SERVER_IP:$SERVER_PORT
# ENDWG

# echo
# echo "OK"

if ! ip route show table $HARDWARE_ROUTE_TABLE 2>/dev/null | grep -q .
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
	ip route show table $HARDWARE_ROUTE_TABLE | sed -e $'s/^/\t/'
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
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut -d$'\t' -f2 | cut -d: -f1)"

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
	echo ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10
	sudo ip rule add fwmark 51820 lookup $HARDWARE_ROUTE_TABLE pref 10

	if ! ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo ip link add "$PIA_INTERFACE" type wireguard
		sudo ip link add "$PIA_INTERFACE" type wireguard
	fi

	echo wg set "$PIA_INTERFACE" fwmark 51820 private-key "$CLIENT_PRIVATE_KEY"         peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0"
	sudo wg set "$PIA_INTERFACE" fwmark 51820 private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0"

	echo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
	sudo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"

	if ip link list $PIA_INTERFACE > /dev/null
	then
		OLD_PEER_IP="$(ip -j addr show dev pia | jq '.[].addr_info[].local')"
		OLD_KEY="$(echo $(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2))"
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut -d$'\t' -f2 | cut -d: -f1)"

		echo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
		sudo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
	fi

	echo ip route add default dev "$PIA_INTERFACE"
	sudo ip route add default dev "$PIA_INTERFACE"
fi

echo "PIA Wireguard '$PIA_INTERFACE' configured successfully"

TRIES=0
echo -n "Waiting for connection to stabilise..."
while ! ping -n -c1 -w 5 -s 1280 -I "$PIA_INTERFACE" "$SERVER_VIP" &>/dev/null
do
	echo -n "."
	TRIES=$(( $TRIES + 1 ))
	if [[ $TRIES -ge 20 ]]
	then
		echo "Connection failed to stabilise, try again"
		exit 1
	fi
	sleep 0.5 # so we can catch ctrl+c
done
echo " OK"

if find "$DATAFILE_NEW" -mtime -3 -exec false {} +
then
	echo "PIA endpoint list is stale, Fetching new generation wireguard server list"

	echo curl --max-time 15 --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v4"
	# curl 'https://serverlist.piaservers.net/vpninfo/servers/new' > "$DATAFILE_NEW.temp" || exit 1
	curl --max-time 15 --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --resolve "$WG_CN:443:10.0.0.1" "https://$WG_CN:443/vpninfo/servers/v4" > "$DATAFILE_NEW.temp" ||
	curl --max-time 15 'https://serverlist.piaservers.net/vpninfo/servers/new' > "$DATAFILE_NEW.temp" ||
	exit 0

	if [ "$(jq '.regions | map_values(select(.servers.wg)) | keys' "$DATAFILE_NEW.temp" 2>/dev/null | wc -l)" -le 30 ]
	then
		echo "Bad serverlist retrieved to $DATAFILE_NEW.temp, exiting"
		echo "You can try again if there was a transient error"
		exit 1
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
		if [ -r "${0%/*}/pia-portforward.sh" ]
		then
			"${0%/*}/pia-portforward.sh"
		else
			echo "pia-portforward.sh couldn't be found!"
			exit 1
		fi
	fi
	echo "Note: pia-portforward.sh should be called every ~5 minutes to maintain your forward."
	echo "You could try:"
	echo "    while sleep 5m; do pia-portforward.sh; done"
	echo "or alternately add a cronjob with crontab -e"
fi

exit 0
