#!/bin/bash

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG - if you've symlinked pia-wg.sh, please also symlink that file"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"

if [ -r "$CONNCACHE" ]
then
	jq . "$CONNCACHE"
elif [ -z "$(jq '.regions | .[] | select(.servers.wg[0].ip == "'"$SERVER_IP"'")' "$DATAFILE_NEW")" ]
then
	SERVER_IP_S="$(cut -d. -f1-3 <<< $SERVER_IP)"
	jq '.regions | .[] | select(.servers.wg[0].ip | test("^'"$SERVER_IP_S"'"))' "$DATAFILE_NEW"

	echo "Note: Inexact match for $SERVER_IP_S.* ($SERVER_IP not found)" >/dev/stderr
else
	jq '.regions | .[] | select(.servers.wg[0].ip == "'"$SERVER_IP"'")' "$DATAFILE_NEW"
fi
