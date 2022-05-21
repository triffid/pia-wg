#!/bin/bash

PIA_CONFIG="$(dirname "$(realpath "$(which "$0")")")/pia-config.sh"

if ! [ -r "$PIA_CONFIG" ]
then
	echo "Can't find pia-config.sh at $PIA_CONFIG - if you've symlinked pia-wg.sh, please also symlink that file"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

source "$PIA_CONFIG"

# : ${PINGFILE:="http://cloudflaremirrors.com/archlinux/iso/latest/arch/x86_64/airootfs.sfs.sig"}
# : ${TESTFILE:="http://cloudflaremirrors.com/archlinux/iso/latest/arch/x86_64/airootfs.sfs}

: ${PINGFILE:="https://cloudflaremirrors.com/debian/dists/stable/main/installer-amd64/current/images/MANIFEST"}
: ${TESTFILE:="https://cloudflaremirrors.com/debian/dists/stable/main/installer-amd64/current/images/hd-media/boot.img.gz"}

# MIRRORCACHE="$CONFIGDIR/speedtest-cache.xml"
# 
# function refresh {
# 	echo "Updating Cache..."
# 	curl https://api.gentoo.org/mirrors/distfiles.xml > "${MIRRORCACHE}.temp" || return $?
# 	mv "${MIRRORCACHE}.temp" "$MIRRORCACHE"
# }
# 
# if [ ! -e "$MIRRORCACHE" ]
# then
# 	refresh || exit $?
# fi
# 
# if [ -f "$CONNCACHE" ]
# then
# 	COUNTRY="$(jq -r .country "$CONNCACHE")"
# 	MIRROR="$(xmllint --xpath '/mirrors/mirrorgroup[@country="'"$COUNTRY"'"]/mirror/uri[@protocol="http"]/text()' "$MIRRORCACHE" 2>/dev/null | sort -R | head -n1)"
# 	[ -n "$MIRROR" ] && echo "Found endpoint-local mirror $MIRROR in $(jq -r .name "$CONNCACHE")"
# fi
# 
# if [ -z "$MIRROR" ]
# then
# 	MIRROR="$(xmllint --xpath '/mirrors/mirrorgroup[@country!="CN"]/mirror/uri[@protocol="http"]/text()' "$MIRRORCACHE" | sort -R | head -n1)"
# 	echo "Using $MIRROR"
# fi

: "${SIZE_MB:=10}"
: "${TIME_S:=10}"

: "${SIZE:=$(( $SIZE_MB * 1048576 ))}"

# echo "Checking for test file..."
PINGSTART="$(date +%s.%N)"
# TESTFILE="$(curl -s -S -m 5 "$MIRROR"/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt | tail -n1 | cut -d\  -f1; exit ${PIPESTATUS[0]})"; RET="$?"
curl -s -S -m 5 -r 0-1 "$PINGFILE" > /dev/null || exit $?
PINGEND="$(date +%s.%N)"

echo "Ping: ~"$(bc <<< "($PINGEND - $PINGSTART) * 333")"ms."

DLSTART="$(date +%s.%N)"
DLSIZE="$(curl -m "$(bc <<< "$TIME_S + $PINGEND - $PINGSTART")" -r 0-"$SIZE" -Y "$(( "$SIZE" / "$TIME_S" ))" -y "$TIME_S" "$TESTFILE" | head -c "$SIZE" | wc -c; exit ${PIPESTATUS[0]})"; RET="$?"
DLEND="$(date +%s.%N)"

# ignore curl: (23) Failure writing output to destination
if [ "$RET" -eq 23 ]
then
  RET=0
fi

echo "$(bc <<< "$DLSIZE / 1048576")MB in "$(bc <<< "($DLEND - $DLSTART) * 1000")"ms = "$(bc <<< "$DLSIZE / ($DLEND - $DLSTART) / 131072")"Mbit/s"

if [ "$DLSIZE" -lt "$SIZE" ]
then
  RET=12
fi

# if [ "$RET" -eq 0 ]
# then
# 	if find "$MIRRORCACHE" -mtime -3 -exec false {} +
# 	then
# 		refresh
# 	fi
# fi

exit "$RET"
