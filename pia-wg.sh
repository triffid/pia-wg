#!/bin/bash

# requires data.json from the PIA application /opt/piavpn/etc/data.json in the working dir

USR=""
PASS=""
LOC="uk"

# generated public key
PKEY=""


PIAAPI="https://www.privateinternetaccess.com"
# get token

TOK=$(curl -X POST \
-H "Content-Type: application/json" \
-d "{\"username\":\"$USR\",\"password\":\"$PASS\"}" \
"$PIAAPI/api/client/v2/token" | jq -r '.token')

echo "got token: $TOK"

if [ -z "$TOK" ]; then
  echo "no token, exiting"
  exit 1
fi

WG_URL=$(cat data.json | jq -r ".locations.$LOC.wireguardUDP")

if [ -z "$WG_URL" ]; then
  echo "no wg region, exiting"
  exit 1
fi

# should TLS verify here
curl -Gkv \
  --data-urlencode "pubkey=$PKEY" \
  --data-urlencode "pt=$TOK" \
"https://$WG_URL/addKey"

