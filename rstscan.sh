#!/bin/bash
#
# Copyright 2014 Philipp Winter <phw@nymity.ch>

source log.sh
source config.sh

# The amount of (unspoofed) TCP SYNs used to estimate the destination's backlog
# size.
control_syns=10

# The amount of TCP SYNs which are sent to fill the destination's SYN backlog
# more than 50%.
probing_syns=145

# How long we should wait for SYN/ACKs after sending data.  65 is a reasonable
# value given 5 SYN/ACK retransmissions and exponential backoff in between
# segments.  After 65 seconds, our SYNs should no longer be in the destinations
# backlog.
timeout=65

if [ "$#" -lt 3 ]
then
	echo
	echo "Usage: $0 DST_ADDRESS DST_PORT SPOOFED_ADDRESS [OUTPUT_FILE]"
	echo
	exit 1
fi

dst_addr="$1"
port="$2"
spoofed_addr="$3"

if [ ! -z "$4" ]
then
	outfile="$4"
else
	outfile="$(mktemp '/tmp/rstscan-XXXXXX.pcap')"
fi

log "Beginning RST probing."

log "Invoking tcpdump(8) to capture network data."
tcpdump -i any -n "host ${dst_addr}" -w "${outfile}" &
pid=$!

# Give tcpdump some time to start.
sleep 2

if [ $prober_type = "uncensored" ]
then
	log "Setting iptables rules to ignore RST segments."
	iptables -A OUTPUT -d ${dst_addr} -p tcp --tcp-flags RST RST -j DROP

	log "Sending ${control_syns} control TCP SYN segments to ${dst_addr}:${port}."
	timeout 5 hping3-custom -n -c $control_syns -i u1300 -q -S -L 0 -s 20000 -p ${port} ${dst_addr} &

	# VPS must start sending SYNs before us.
	sleep 1

	# 6,000 usec means ~166.6 SYNs a second.
	log "Sending ${probing_syns} spoofed TCP SYN segments to ${dst_addr}."
	timeout 5 hping3-custom -n -c $probing_syns -a $spoofed_addr -i u6000 -q -S -L 0 -M 1000000 -s 30000 -p ${port} ${dst_addr} &
else
	# 6,000 usec means ~166.6 SYNs a second.
	log "Sending ${probing_syns} TCP SYN segments to ${dst_addr}."
	timeout 5 hping3-custom -n -c $probing_syns -i u6000 -q -S -L 0 -M 1000000 -s 30000 -p ${port} ${dst_addr} &

	# Wait a while to have some certainty that the SYNs made it to the target.
	sleep 2

	# Send RSTs which should reach the destination even though SYN/ACKs are blocked.
	log "Sending ${probing_syns} TCP RST segments to ${dst_addr}."
	timeout 5 hping3-custom -n -c $probing_syns -i u13000 -q -R -L 0 -M 1000001 -s 30000 -p ${port} ${dst_addr} &
fi

log "Done transmitting but waiting ${timeout}s for final SYN/ACKs to arrive."
sleep "$timeout"

if [ $prober_type = "uncensored" ]
then
	log "Removing iptables rule."
	iptables -D OUTPUT -d ${dst_addr} -p tcp --tcp-flags RST RST -j DROP
fi

log "Terminating tcpdump."
if [ ! -z "$pid" ]
then
	kill "$pid"
	log "Sent SIGTERM to tcpdump's PID ${pid}."
fi

log "Experimental results written to: ${outfile}"
