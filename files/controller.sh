#!/usr/bin/env bash

PRIMARY_IP4=$(ip route get 255.255.255.255 | tr -s ' ' | grep -oE 'src [0-9\.]+' | cut -d' ' -f2)
PRIMARY_IP6=$(ip route get ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff | tr -s ' ' | grep -oE 'src [0-9a-f:]+' | cut -d' ' -f2)

function set_down() {
	ip link show dummy0 1> /dev/null 2> /dev/null || return 0
	ipset flush v4
	ipset flush v6
	birdc disable static4
	birdc disable static6
	log "Setting dummy0 link down ..."
	ip link del dummy0 type dummy
}
function set_up() {
	ip link show dummy0 1> /dev/null 2> /dev/null && return 0
	tmptable=$(head -c128 /dev/urandom | md5sum | head -c 8)
	(
		echo "create ${tmptable}-v4 hash:ip,port family inet hashsize 1024 maxelem 65536"
		echo "create ${tmptable}-v6 hash:ip,port family inet6 hashsize 1024 maxelem 65536"
		ss -nltu | cat | awk '($1 == "tcp" || $1 == "udp") && ($6 == ":::*" || $6 == "*:*") {print $1, $5}' | sed -r 's/:([0-9]+)$/ \1/' | tr -d '[]' | awk '$2 != "*" && $2 != "::" && $2 != "::1" && $2 !~ "^127\\\."' | sort -u | while read proto ip port; do
			if echo "${ip}" | fgrep -q :; then
				echo "add ${tmptable}-v6 ${ip},${proto}:${port}"
				echo "add ${tmptable}-v6 ${ip},ipv6-icmp:echo-request"
				echo "add ${tmptable}-v6 ${ip},ipv6-icmp:packet-too-big"
			else
				echo "add ${tmptable}-v4 ${ip},${proto}:${port}"
				echo "add ${tmptable}-v4 ${ip},icmp:echo-request"
				echo "add ${tmptable}-v4 ${ip},icmp:fragmentation-needed"
			fi
		done | sort -u
	) | ipset restore
	ipset swap "v4" "${tmptable}-v4"
	ipset swap "v6" "${tmptable}-v6"
	ipset destroy "${tmptable}-v4"
	ipset destroy "${tmptable}-v6"
	birdc enable static4
	birdc enable static6
	log "Setting dummy0 link up ..."
	ip link add dummy0 type dummy
	log "Adding prefixes ..."
	for bgpprefix in ${BGP_PREFIXES}; do
		log "... ${bgpprefix}"
		ip route add local "${bgpprefix}" dev dummy0
	done
}

function log() {
        echo "$(date -u) ${*}"
}

set_down

function cleanup() {
	set_down
	exit 0
}

trap "cleanup" HUP INT QUIT KILL TERM

while true; do
	if curl -sf --unix-socket /var/run/docker.sock http://localhost/containers/json 2> /dev/null | jq -Mcr '.[].Id' 2> /dev/null | xargs -n1 -P1 -I% curl -sf --unix-socket /var/run/docker.sock http://localhost/containers/%/json 2> /dev/null | jq -Mcrs 'map(select(.State.Health != null)) | .[].State.Health.Status' 2> /dev/null | grep -qvE '^healthy$'; then
		set_down
	else
		set_up
	fi
	sleep 5
done