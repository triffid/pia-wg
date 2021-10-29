#!/bin/bash

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG - if you've symlinked pia-wg.sh, please also symlink that file"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

MIRRORCACHE="$CONFIGDIR/speedtest-cache.xml"

function refresh {
	echo "Updating Cache..."
	curl https://api.gentoo.org/mirrors/distfiles.xml > "${MIRRORCACHE}.temp" || return $?
	mv "${MIRRORCACHE}.temp" "$MIRRORCACHE"
}

if [ ! -e "$MIRRORCACHE" ]
then
	refresh || exit $?
fi

if [ -f "$CONNCACHE" ]
then
	COUNTRY="$(jq -r .country "$CONNCACHE")"
	MIRROR="$(xmllint --xpath '/mirrors/mirrorgroup[@country="'"$COUNTRY"'"]/mirror/uri[@protocol="http"]/text()' "$MIRRORCACHE" 2>/dev/null | sort -R | head -n1)"
	[ -n "$MIRROR" ] && echo "Found endpoint-local mirror $MIRROR in $(jq -r .name "$CONNCACHE")"
fi

if [ -z "$MIRROR" ]
then
	MIRROR="$(xmllint --xpath '/mirrors/mirrorgroup[@country!="CN"]/mirror/uri[@protocol="http"]/text()' "$MIRRORCACHE" | sort -R | head -n1)"
fi

: "${SIZE_MB:=10}"
: "${TIME_S:=10}"

: "${SIZE:=$(( $SIZE_MB * 1048576 ))}"

echo "Checking for test file..."
PINGSTART="$(date +%s.%N)"
TESTFILE="$(curl -s -S -m 5 "$MIRROR"/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt | tail -n1 | cut -d\  -f1; exit ${PIPESTATUS[0]})"; RET=$?
[ $RET -ne 0 ] && exit $RET
PINGEND="$(date +%s.%N)"

echo "Ping: ~"$(bc <<< "($PINGEND - $PINGSTART) * 200")"ms. Testing with $MIRROR/releases/amd64/autobuilds/$TESTFILE"

DLSTART="$(date +%s.%N)"
DLSIZE="$(curl -m "$(bc <<< "$TIME_S + $PINGEND - $PINGSTART")" -r 0-"$SIZE" "$MIRROR"/releases/amd64/autobuilds/"$TESTFILE" | wc -c; exit ${PIPESTATUS[0]})"; RET=$?
DLEND="$(date +%s.%N)"

echo "$(bc <<< "$DLSIZE / 1048576")MB in "$(bc <<< "($DLEND - $DLSTART) * 1000")"ms = "$(bc <<< "$DLSIZE / ($DLEND - $DLSTART) / 131072")"Mbit/s"

if find "$MIRRORCACHE" -mtime -3 -exec false {} +
then
	refresh
fi

exit $RET
