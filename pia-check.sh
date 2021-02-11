#!/bin/bash

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG - if you've symlinked pia-wg.sh, please also symlink that file"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

ping -n -w5 -W0.5 -c5 "$SERVER_VIP"
