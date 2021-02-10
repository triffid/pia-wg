#!/bin/bash

if [ -t 1 ]
then
	BOLD=$'\e[1m'
	NORMAL=$'\e[0m'
fi
TAB=$'\t'

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

if [ -z "$CLIENT_PRIVATE_KEY" ]
then
	echo "Generating new private key"
	CLIENT_PRIVATE_KEY="$(wg genkey)"
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	CLIENT_PUBLIC_KEY=$(wg pubkey <<< "$CLIENT_PRIVATE_KEY")
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	echo "Failed to generate client public key, check your config!"
	exit 1
fi

if [ -z "$LOC" ]
then
	echo "Setting default location: ${BOLD}any${NORMAL}"
	LOC="."
fi

if [ -z "$PIA_INTERFACE" ]
then
	echo "Setting default wireguard interface name: ${BOLD}pia${NORMAL}"
	PIA_INTERFACE="pia"
fi

if [ -z "$WGCONF" ]
then
	WGCONF="$CONFIGDIR/${PIA_INTERFACE}.conf"
fi

if [ -z "$PIA_CERT" ]
then
	PIA_CERT="$CONFIGDIR/rsa_4096.crt"
fi

if [ -z "$TOKENFILE" ]
then
	TOKENFILE="$CONFIGDIR/token"
fi

if [ -z "$TOK" ] && [ -r "$TOKENFILE" ]
then
	TOK=$(< "$TOKENFILE")
fi

if [ -z "$DATAFILE" ]
then
	DATAFILE="$CONFIGDIR/data.json"
fi

if [ -z "$DATAFILE_NEW" ]
then
	DATAFILE_NEW="$CONFIGDIR/data_new.json"
fi

if [ -z "$REMOTEINFO" ]
then
	REMOTEINFO="$CONFIGDIR/remote.info"
fi

if [ -z "$CONNCACHE" ]
then
	CONNCACHE="$CONFIGDIR/cache.json"
fi

if [ -z "$HARDWARE_ROUTE_TABLE" ]
then
	# 0xca6c
	HARDWARE_ROUTE_TABLE=51820
fi

if [ -z "$VPNONLY_ROUTE_TABLE" ]
then
	# 0xca6d
	VPNONLY_ROUTE_TABLE=51821
fi

if [ -z "$PF_SIGFILE" ]
then
	PF_SIGFILE="$CONFIGDIR/pf-sig"
fi

if [ -z "$PF_BINDFILE" ]
then
	PF_BINDFILE="$CONFIGDIR/pf-bind"
fi
