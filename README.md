# Private Internet Access wireguard shell scripts

## Prelude

* [Private Internet Access (PIA)](https://privateinternetaccess.com) is a VPN provider that claims a strict interest in privacy and [does not log user traffic](https://www.privateinternetaccess.com/helpdesk/kb/articles/do-you-log-3).

* [WireGuard](https://wireguard.com) is a relatively new VPN protocol written by a consortium of Linux developers and cryptographers, designed to be small, simple, efficient, and avoid many of the pitfalls of other popular VPN protocols.

## Usage

These scripts have been tested on Gentoo Linux, but _should_ work with other Linux distributions.

They have not been tested on OSX but might work - pull requests are welcomed as long as they don't adversely affect the functionality on Linux, or excessively complicate the scripts.

Windows is entirely out of scope for this project.

### pia-wg

`./pia-wg.sh [-r] [-c]`

* **-r** (reload/reconnect)<br>
Hop to a new server or re-submit keys to selected server, even if a cached connection profile is available
* **-c** (config only)<br>
Only generate config, do not affect current system - useful for generating configs for routers and similar devices, or WireGuard's Android/iOS apps (if you don't like the PIA app)<br>
The generated config will be stored at `~/.config/pia-wg/pia.conf` or `/var/cache/pia-wg/pia.conf` - where the filename is based on the `PIA_INTERFACE` value in your config (default "`pia`")<br>
if `qrencode` is available, will also print a QR code to your terminal that can be scanned by the Wireguard mobile app.

During the first run, `pia-wg` will grab PIA's encryption key and initial server list, prompt for your PIA login credentials, and fetch an authentication token from PIA before proceeding to set up a wireguard connection.

By default, it saves your settings in `~/.config/pia-wg/pia-wg.conf` (when run as user) or `/var/cache/pia-wg/pia-wg.conf` (when run as root or under `sudo`) - and saves other data (eg auth token, server list, cached connection, port-forward token, etc) in the same folder.

You can edit the config at any time, and examine other cached files in that folder.

`pia-wg` will attempt to automatically configure your routing tables and rules, but if you already have a suitable configuration, you can tell it which routing tables to use by setting `HARDWARE_ROUTE_TABLE` (table should only have hardlinks such as ethernet/wifi, wireguard packets are sent via this table) and/or `VPNONLY_ROUTE_TABLE` (table should be empty except for the PIA wireguard link, you can configure your system to force certain types of packets to use this table)

After a successful connection, `pia-wg` will check if the cached serverlist is more than 3 days old, and if so, fetch a new list over the VPN connection.<br>
In this way, this script never needs to fetch updates outside a VPN link after initial setup is complete.

It will also optionally call `pia-portforward.sh` if you have set PORTFORWARD="any text" in your `pia-wg.conf`.

If `pia-wg.sh` is run under a user account without the `-c` flag, it will (eventually) invoke `sudo` to apply various settings to your system.<br>
Presumably `sudo` will request your user's password at this time depending on your `sudoers` configuration.

### pia-portforward

pia-portforward.sh is automatically run _once_ by `pia-wg` if you write `PORTFORWARD="any text"` in your pia-wg.conf - also, `pia-wg` will only select portforward-capable servers if this option is set.

You can run it manually to check your port-forward status or find out which port you have assigned.

If you want to maintain your forwarded port, it should be called every ~5 minutes - setting up a _cron job_ or similar to do this automatically is beyond the scope of this document.

### pia-check and pia-currentserver

These are utility scripts - `pia-check.sh` will ping the remote endpoint over the VPN link to ensure it's still working, and `pia-currentserver` will print the cached connection information for the current or most recent connection.

### openrc-init-pia

This is an example openrc init script to start a PIA vpn connection during boot.

It assigns the "reload" action to hop servers, demonstrating the ability to reuse a cached connection on boot but optionally hop servers at any time.

### pia-config.sh

This script is intentionally non-executable, and does almost nothing if fed directly to bash - it may generate a wireguard key pair if you don't have one, but that's all.

It is a utility script that provides a common place for the above scripts to share default config settings, and is only intended to be included from the executable scripts.

## Requirements

Standard Linux userland, with functioning `bash`, `which`, `realpath`, `grep`, `cut`, etc.

Additionally, it will check for the presence of `curl`, `jq`, `ip` (iproute2), `wg` (wireguard-tools) and fail if they are absent.

The `qrencode` utility is optional, but is called when `-c` is specified to print a QR code for the generated config.

## Notes

* [PIA have published their own shell scripts](https://github.com/pia-foss/manual-connections) with somewhat similar functionality, but a significantly different scope and target audience.<br>

* These scripts are carefully designed to not need working DNS after the initial setup, since they were written for places where PIA is ostensibly blocked.<br>
During initial setup in such places however, you may have to use an alternate connection method so that the auth token can be fetched from PIA's API, and the initial serverlist and PIA encryption key can be downloaded.

* While these scripts are designed to have a robust quantity of automation and error checking, pull requests for improvements are always welcome.

* The routing tables and rules are designed to gracefully handle connection changes (eg ethernet/wifi/mobile handover) since WireGuard itself is designed to gracefully handle this - however this requires your system to dynamically update the hardware-only routing table as required by adding new routes and removing stale ones.<br>
Configuring your system to do this is beyond the scope of this document.

* In [this comment](https://github.com/pia-foss/manual-connections/pull/111#issuecomment-822824399), PIA have stated that stale wireguard configs will be flushed within "several hours", so generated configs are of little utility on devices that aren't online 24/7.<br>
Also, PIA's servers are rebooted periodically ("every few months"), and all wireguard configs will be lost at that time since the servers do not retain any state across reboots.

* While empirical testing suggests that authentication tokens seem to last for many months at least, [PIA state in their own scripts](https://github.com/pia-foss/manual-connections/blob/742a492/get_token.sh#L94) that the authentication token only has a validity of 24 hours.<br>
This could be related to fetching tokens from either their v2 or v3 API - this script prefers the v2 API, and will try v3 if v2 fails.<br>
The documented token expiry schedule may make it necessary to store your unobfuscated PIA account password in the future.
