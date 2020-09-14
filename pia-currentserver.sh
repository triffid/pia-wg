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

if [ -z "$DATAFILE_NEW" ]
then
	DATAFILE_NEW="$CONFIGDIR/data_new.json"
fi

if [ -z "$REMOTEINFO" ]
then
	REMOTEINFO="$CONFIGDIR/remote.info"
fi

if [ -r "$CONFIG" ]
then
	source "$CONFIG"
fi

SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"

if [ -z "$(jq '.regions | .[] | select(.servers.wg[0].ip == "'"$SERVER_IP"'")' "$DATAFILE_NEW")" ]
then
	SERVER_IP_S="$(cut -d. -f1-3 <<< $SERVER_IP)"
	jq '.regions | .[] | select(.servers.wg[0].ip | test("^'"$SERVER_IP_S"'"))' "$DATAFILE_NEW"

	echo "Note: Inexact match for $SERVER_IP_S.* ($SERVER_IP not found)" >/dev/stderr
else
	jq '.regions | .[] | select(.servers.wg[0].ip == "'"$SERVER_IP"'")' "$DATAFILE_NEW"
fi
