#!/bin/sh
# Prints the Crateyard VM's macOS memory footprint before, during and after a Postgres load.
set -eu
export DOCKER_HOST=unix://$HOME/.crateyard/docker.sock
vm=$(ps -axo pid=,ppid=,command= | awk '/com.apple.Virtualization.VirtualMachine/ && !/awk/ {print $1}' | while read -r p; do
	lsof -p "$p" 2>/dev/null | grep -q "/.crateyard/data.img" && echo "$p"
done | head -1)
fp() { footprint -p "$vm" 2>/dev/null | awk '/phys_footprint:/{print $2" "$3}'; }

echo "idle:           $(fp)"
docker run -d --name memtest -e POSTGRES_PASSWORD=x postgres:16-alpine >/dev/null
until docker exec memtest pg_isready -q 2>/dev/null; do sleep 1; done
docker exec memtest pgbench -U postgres -i -s 60 -q postgres >/dev/null 2>&1
docker exec memtest pgbench -U postgres -c 4 -T 20 postgres 2>/dev/null | awk '/^tps/{print "pgbench:        "$3" tps"}'
echo "under load:     $(fp)"
docker rm -f memtest >/dev/null
echo "just removed:   $(fp)"
sleep 15; echo "after 15s:      $(fp)"
sleep 15; echo "after 30s:      $(fp)"
sleep 30; echo "after 60s:      $(fp)"
