#!/bin/bash

MIRROR="${MIRROR:-https://mirror.rackspace.com/gentoo}"
SIZE_MB="${SIZE_MB:-10}"
TIME_S="${TIME_S:-10}"

SIZE="${SIZE:-$(( $SIZE_MB * 1048576 ))}"

PINGSTART="$(date +%s.%N)"
TESTFILE="$(curl -s -S "$MIRROR"/releases/amd64/autobuilds/latest-stage3-amd64-desktop-systemd.txt | tail -n1 | cut -d\  -f1)"
PINGEND="$(date +%s.%N)"

echo "Ping: ~"$(bc <<< "($PINGEND - $PINGSTART) * 200")"ms. Testing with $MIRROR/releases/amd64/autobuilds/$TESTFILE"

DLSTART="$(date +%s.%N)"
curl -m "$TIME_S" -r 0-"$SIZE" "$MIRROR"/releases/amd64/autobuilds/"$TESTFILE" > /dev/null; RET=$?
DLEND="$(date +%s.%N)"

echo "$(( SIZE / 1048576 ))MB in "$(bc <<< "($DLEND - $DLSTART) * 1000")"ms = "$(bc <<< "$SIZE / ($DLEND - $DLSTART) / 125000")"Mbit/s"

exit $RET

#while ! curl -m 10 -r 0-$((10 * 1048576)) "$MIRROR"/releases/amd64/autobuilds/"$TESTFILE" > /dev/null
#do
#	service net.pia reload
#done
