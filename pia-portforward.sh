#!/bin/bash

if [ -z "$CONFIGDIR" ]
then
	if [ $EUID -eq 0 ]
	then
		CONFIGDIR="/var/cache/pia-wg"
	else
		CONFIGDIR="$HOME/.config/pia-wg"
	fi
	mkdir -p "$CONFIGDIR"
fi

if [ -z "$CONFIG" ]
then
	if [ $EUID -eq 0 ]
	then
		CONFIG="/etc/pia-wg/pia-wg.conf"
	else
		CONFIG="$CONFIGDIR/pia-wg.conf"
	fi
fi

if [ -r "$CONFIG" ]
then
	source "$CONFIG"
fi

if [ -z "$DATAFILE_NEW" ]
then
	DATAFILE_NEW="$CONFIGDIR/data_new.json"
fi

if [ -z "$REMOTEINFO" ]
then
	REMOTEINFO="$CONFIGDIR/remote.info"
fi

if [ -z "$TOKENFILE" ]
then
	TOKENFILE="$CONFIGDIR/token"
fi

if [ -z "$PIA_CERT" ]
then
	PIA_CERT="$CONFIGDIR/rsa_4096.crt"
fi

if [ -z "$TOK" ] && [ -r "$TOKENFILE" ]
then
	TOK="$(< "$TOKENFILE")"
else
	echo "Can't find token $TOKENFILE"
	exit 1
fi

if [ -z "$PIA_INTERFACE" ]
then
	PIA_INTERFACE="pia"
fi

if [ -z "$PF_SIGFILE" ]
then
	PF_SIGFILE="$CONFIGDIR/pf-sig"
fi

if [ -z "$PF_BINDFILE" ]
then
	PF_BINDFILE="$CONFIGDIR/pf-bind"
fi

PEER_IP="$(jq -r .peer_ip "$REMOTEINFO")"
SERVER_PUBLIC_KEY="$(jq -r .server_key  "$REMOTEINFO")"
SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"
SERVER_PORT="$(jq -r .server_port "$REMOTEINFO")"
SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

WG_INFO="$(jq '.regions | .[] | select(.servers.wg[0].ip == "'"$SERVER_IP"'")' "$DATAFILE_NEW")"

if [ -z "$WG_INFO" ]
then
	SERVER_IP_S="$(cut -d. -f1-3 <<< $SERVER_IP)"
	WG_INFO="$(jq '.regions | .[] | select(.servers.wg[0].ip | test("^'"$SERVER_IP_S"'"))' "$DATAFILE_NEW")"
fi

if [ -z "$WG_INFO" ]
then
	echo "Couldn't determine server information even with fuzzy search, is your $DATAFILE_NEW ok?" >/dev/stderr
	exit 1
fi

if [ "$(jq -r .port_forward <<< "$WG_INFO")" != true ]
then
	echo "Current server doesn't support port forwarding:"
	jq . <<< "$WG_INFO"
	exit 1
fi

WG_NAME="$(jq -r .name <<< "$WG_INFO")"
WG_DNS="$(jq -r .dns <<< "$WG_INFO")"

WG_HOST="$(jq -r '.servers.wg[0].ip' <<< "$WG_INFO")"
WG_CN="$(jq -r '.servers.wg[0].cn' <<< "$WG_INFO")"

# sections of the below adapted from Threarah's work at
# https://github.com/thrnz/docker-wireguard-pia/blob/003f79f3b6ba24387e10d7de63ec62e98e6518a5/run#L233-L270 with permission
# Also see https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fxhkpjt/

if [ -r "$PF_SIGFILE" ]
then
	PF_SIG="$(< "$PF_SIGFILE")"

	PF_PAYLOAD_RAW=$(jq -r .payload <<< "$PF_SIG")
	PF_PAYLOAD=$(base64 -d <<< "$PF_PAYLOAD_RAW")
	PF_TOKEN_EXPIRY_RAW=$(jq -r .expires_at <<< "$PF_PAYLOAD")
	PF_TOKEN_EXPIRY=$(date --date="$PF_TOKEN_EXPIRY_RAW" +%s)
fi

if [ $(( "$PF_TOKEN_EXPIRY" - $(date -u +%s) )) -le 900 ]
then
	echo "Signature stale, refetching"
	exit 1

	# Very strange - must connect via 10.0/8 private VPN link to the server's public IP - why?
	# I tried SERVER_VIP (10.0/8 private IP) instead of SERVER_IP (public IP) but it won't connect
	# It also won't connect if you try to connect from the internet, hence needing --interface "$PIA_INTERFACE"
	PF_SIG="$(curl --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --get --silent --show-error --retry 5 --retry-delay 5 --max-time 15 --data-urlencode token@/dev/fd/3 --resolve "$WG_CN:19999:$SERVER_IP" "https://$WG_CN:19999/getSignature" 3< <(echo -n "$TOK") | tee "$PF_SIGFILE")"

	PF_STATUS="$(jq -r .status <<< "$PF_SIG")"
	if [ "$PF_STATUS" != "OK" ]
	then
		echo "Signature retrieval failed: $PF_STATUS"
		jq . <<< "$PF_SIG"
		exit 1
	fi

	PF_PAYLOAD_RAW=$(jq -r .payload <<< "$PF_SIG")
	PF_PAYLOAD=$(base64 -d <<< "$PF_PAYLOAD_RAW")
	PF_TOKEN_EXPIRY_RAW=$(jq -r .expires_at <<< "$PF_PAYLOAD")
	PF_TOKEN_EXPIRY=$(date -D %Y-%m-%dT%H:%M:%S --date="$PF_TOKEN_EXPIRY_RAW" +%s)
fi

PF_GETSIGNATURE=$(jq -r .signature <<< "$PF_SIG")
PF_PORT=$(jq -r .port <<< "$PF_PAYLOAD")

PF_BIND="$(curl --interface "$PIA_INTERFACE" --CAcert "$PIA_CERT" --get --silent --show-error --retry 5 --retry-delay 5 --max-time 15 --data-urlencode payload@/dev/fd/3 --data-urlencode signature@/dev/fd/4 --resolve "$WG_CN:19999:$SERVER_IP" "https://$WG_CN:19999/bindPort" 3< <(echo -n "$PF_PAYLOAD_RAW") 4< <(echo -n "$PF_GETSIGNATURE") )"

PF_STATUS="$(jq -r .status <<< "$PF_BIND")"
if [ "$PF_STATUS" != "OK" ]
then
	echo "Bind failed: $PF_STATUS"
	jq . <<< "$PF_BIND"
	exit 1
fi

( echo -n "PIA Server->Bind: "; jq -r .message <<< "$PF_BIND"; ) > /dev/stderr

echo > /dev/stderr
echo -n "Bound port: " > /dev/stderr
echo "$PF_PORT"
echo > /dev/stderr

###############################################################################
#                                                                             #
# TODO: make this more flexible for others' systems                           #
#                                                                             #
###############################################################################

transmission-remote -p "$PF_PORT" -pt

###############################################################################
#                                                                             #
#                                                                             #
#                                                                             #
###############################################################################

exit 0
