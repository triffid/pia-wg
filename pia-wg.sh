#!/bin/bash

# original scrpt posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

if [ -z "$CONFIG" ]
then
	CONFIG="pia-wg.conf"
fi

if [ -r "$CONFIG" ]
then
	source "$CONFIG"
fi

if [ -z "$CLIENT_PRIVATE_KEY" ]
then
	echo "Generating private key"
	CLIENT_PRIVATE_KEY="$(wg genkey)"
fi

if [ -z "$LOC" ]
then
	echo "Setting default location: US (any, using pattern match)"
	LOC="us"
fi

if [ -z "$PIA_INTERFACE" ]
then
	echo "Setting default wireguard interface name: pia"
	PIA_INTERFACE="pia"
fi

# get token
if [ -z "$TOK" ] && [ -r .token ]
then
	TOK=$(< .token)
fi

echo $TOK

if [ -z "$TOK" ] && ([ -z "$USER" ] || [ -z "$PASS" ])
then
	if [ -z "$USER" ]
	then
		read -p "Please enter your privateinternet.com username: " USER
	fi
	if [ -z "$PASS" ]
	then
		echo "If you do not wish to save your password, and want to be asked every time an auth token is required, simply press enter now"
		read -p "Please enter your privateinternet.com password: " -s PASS
	fi
	cat <<ENDCONFIG > "$CONFIG"
# your privateinternetaccess.com username (not needed if you already have an auth token)
USER="$USER"
# your privateinternetaccess.com password (not needed if you already have an auth token)
PASS="$PASS"

# your desired endpoint location
LOC="$LOC"

# the name of the network interface
PIA_INTERFACE="$PIA_INTERFACE"

# generate this with "wg genkey"
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"

ENDCONFIG
	echo "Config saved"
fi

# fetch data.json if missing
if ! [ -r data.json ]
then
	echo "Fetching wireguard server list from github"
	wget -O data.json 'https://raw.githubusercontent.com/pia-foss/desktop/master/tests/res/openssl/payload1/payload' || exit 1
fi

if [ "$(jq -r .$LOC data.json)" == "null" ]
then
	echo "No exact match for location \"$LOC\" trying pattern"
	# from https://unix.stackexchange.com/questions/443884/match-keys-with-regex-in-jq/443927#443927
	LOC=$(jq 'with_entries(if (.key|test("^'$LOC'")) then ( {key: .key, value: .value } ) else empty end ) | keys' data.json | grep ^\  | cut -d\" -f2 | shuf -n 1)
fi

if [ "$(jq -r .$LOC data.json)" == "null" ]
then
	echo "Location $LOC not found!"
	echo "Options are:"
	jq keys data.json
	echo
	echo "Please edit $CONFIG and change your desired location, then try again"
	exit 1
fi

if [ -z "$TOK" ]
then
	if [ -z "$PASS" ]
	then
		echo "A new auth token is required, and you have not saved your password."
		echo "Your password will NOT be saved if you enter it now."
		read -p "Please enter your privateinternetaccess.com password for $USER: " -s PASS
	fi
	TOK=$(curl -X POST \
	-H "Content-Type: application/json" \
	-d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
	"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')

	echo "got token: $TOK"
fi

if [ -z "$TOK" ]; then
  echo "Failed to authenticate with privateinternetaccess"
  exit 1
fi

echo "$TOK" > .token

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	CLIENT_PUBLIC_KEY=$(wg pubkey <<< $CLIENT_PRIVATE_KEY)
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	echo "Failed to generate client public key, check your config!"
	exit 1
fi

WG_URL=$(cat data.json | jq -r ".$LOC.wireguard.host")
WG_SERIAL=$(cat data.json | jq -r ".$LOC.wireguard.serial")
WG_HOST=$(cut -d: -f1 <<< "$WG_URL")
WG_PORT=$(cut -d: -f2 <<< "$WG_URL")

if [ -z "$WG_URL" ]; then
  echo "no wg region, exiting"
  exit 1
fi

echo "Registering public key with PIA endpoint $LOC ($WG_HOST)"

# should TLS verify here
# can't verify fully as PIA's wireguard endpoint certs don't have a chain back to a root CA
curl -GksS \
  --data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
  --data-urlencode "pt=$TOK" \
  --resolve "$WG_SERIAL:$WG_PORT:$WG_HOST" \
"https://$WG_SERIAL:$WG_PORT/addKey" | tee remote.info.temp || exit 1

if [ "$(jq -r .status remote.info.temp)" != "OK" ]
then
	echo "WG key registration failed - bad token?"
	echo "If you get an auth error, consider deleting .token and getting a new one"
	exit 1
fi

mv remote.info.temp \
	remote.info

PEER_IP="$(jq -r .peer_ip     remote.info)"
SERVER_PUBLIC_KEY="$(jq -r .server_key  remote.info)"
SERVER_IP="$(jq -r .server_ip   remote.info)"
SERVER_PORT="$(jq -r .server_port remote.info)"

if [ -z "$WGCONF" ]
then
	WGCONF="${PIA_INTERFACE}.conf"
fi

echo "Generating $WGCONF"
echo

tee "$WGCONF" <<ENDWG
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address    = $PEER_IP
Table      = off
# DNS        = $(jq -r '.dns_servers[0:2]' remote.info | grep ^\  | cut -d\" -f2 | xargs echo | sed -e 's/ /,/g')

[Peer]
PublicKey  = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint   = $SERVER_IP:$SERVER_PORT
ENDWG

echo
echo "OK"

echo "Bringing up wireguard interface $PIA_INTERFACE... "
if [ $EUID -eq 0 ]
then
	wg-quick down "./$WGCONF"

	GATEWAY_IP=$(ip route show | grep ^default | grep via | head -n1 | perl -ne '/via (\S+)/ && print "$1\n";')
	GATEWAY_DEV=$(ip route show | grep ^default | grep via | head -n1 | perl -ne '/dev (\S+)/ && print "$1\n";')
	ip route add $SERVER_IP via $GATEWAY_IP dev $GATEWAY_DEV

	wg-quick up "./$WGCONF"
else
	echo wg-quick down "./$WGCONF"
	sudo wg-quick down "./$WGCONF"

	GATEWAY_IP= $(ip route show | grep ^default | grep via | head -n1 | perl -ne '/via (\S+)/ && print "$1\n";')
	GATEWAY_DEV=$(ip route show | grep ^default | grep via | head -n1 | perl -ne '/dev (\S+)/ && print "$1\n";')
	echo ip route add $SERVER_IP via $GATEWAY_IP dev $GATEWAY_DEV
	sudo ip route add $SERVER_IP via $GATEWAY_IP dev $GATEWAY_DEV

	echo wg-quick up "./$WGCONF"
	sudo wg-quick up "./$WGCONF"
fi

echo "Done"
