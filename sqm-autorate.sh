#!/bin/sh

# automatically adjust bandwidth for CAKE in dependence on detected load and RTT

# inspired by @moeller0 (OpenWrt forum)
# initial sh implementation by @Lynx (OpenWrt forum)
# requires packages: iputils-ping, coreutils-date and coreutils-sleep

debug=0
enable_verbose_output=1 	# Enable (1) or disable (0) output monitoring lines showing bandwidth changes
ul_if=br-lan 				# Upload interface
dl_if=ifb4br-lan 			# Download interface

# Swapped upload/download rates because the interface is a LAN interface (ingress/egress swapped)
max_ul_rate=85000 			# Maximum bandwidth for egress
min_ul_rate=8000			# Minimum bandwidth for egress
max_dl_rate=22000 			# Maximum bandwidth for ingress
min_dl_rate=16000 			# Minimum bandwidth for ingress
tick_duration=2				# Seconds to wait between ticks

load_thresh=0.5             # % of currently set bandwidth for detecting high load
goal_deviation=30           # Goal standard deviation (variance) in pings
rate_adjust_dev_high=0.01   # Percent to reduce by if the deviation is high
rate_adjust_load_high=0.05	# How rapidly to increase bandwidth upon high load detected
rate_adjust_load_low=0.001  # Percent to reduce by if the rate is low

# verify these are correct using 'cat /sys/class/...'
case "${dl_if}" in
    \veth*) 
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
    	;;
    \ifb*) 
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/tx_bytes"
    	;;
    *) 
        rx_bytes_path="/sys/class/net/${dl_if}/statistics/rx_bytes"
	;;
esac

case "${ul_if}" in
    \veth*) 
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
    	;;
    \ifb*) 
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/rx_bytes"
    	;;
    *) 
        tx_bytes_path="/sys/class/net/${ul_if}/statistics/tx_bytes"
	;;
esac

if [ "$debug" ] ; then
    echo "rx_bytes_path: $rx_bytes_path"
    echo "tx_bytes_path: $tx_bytes_path"
fi

cur_deviation=0.0
# Get average of the standard deviation across entire set of reflectors
get_mdev() {
    cur_deviation=$(echo $(/usr/bin/ping -i 0.04 -c 15 1.0.0.1 | tail -1 | awk '{print $4}' | cut -d '/' -f 4) )
    wait
}

call_awk() {
  printf '%s' "$(awk 'BEGIN {print '"${1}"'}')"
}

get_next_shaper_rate() {
    local cur_rate
    local min_rate
    local max_rate
    local cur_load
    local next_rate

    cur_rate=$1
    min_rate=$2
    max_rate=$3
    cur_load=$4

    # in case of supra-threshold RTT spikes decrease the rate unconditionally
	if awk "BEGIN {exit !($cur_deviation >= $goal_deviation)}"; then
	    next_rate=$( call_awk "int(${cur_rate} - $rate_adjust_dev_high * (${max_rate} - ${min_rate}) )" )
        else
	    # ... otherwise take the current load into account
	    # high load, so we would like to increase the rate
	    if awk "BEGIN {exit !(${cur_load} >= $load_thresh)}"; then
                next_rate=$( call_awk "int(${cur_rate} + $rate_adjust_load_high * (${max_rate} - ${min_rate}) )" )
	    else
	        # low load gently decrease the rate again
		        next_rate=$( call_awk "int(${cur_rate} - ${rate_adjust_load_low} * (${max_rate} - ${min_rate}) )" )
        fi
	fi

	# make sure to only return rates between cur_min_rate and cur_max_rate
    if awk "BEGIN {exit !($next_rate < $min_rate)}"; then
        next_rate=$min_rate;
    fi

    if awk "BEGIN {exit !($next_rate > $max_rate)}"; then
        next_rate=$max_rate;
    fi
    echo "${next_rate}"
}

# update download and upload rates for CAKE
function update_rates {
    cur_rx_bytes=$(cat $rx_bytes_path)
    cur_tx_bytes=$(cat $tx_bytes_path)
    t_cur_bytes=$(date +%s.%N)
        
    rx_load=$( call_awk "(8/1000)*(${cur_rx_bytes} - ${prev_rx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_dl_rate}) " )
   	tx_load=$( call_awk "(8/1000)*(${cur_tx_bytes} - ${prev_tx_bytes}) / (${t_cur_bytes} - ${t_prev_bytes}) * (1/${cur_ul_rate}) " )

    t_prev_bytes=$t_cur_bytes
    prev_rx_bytes=$cur_rx_bytes
    prev_tx_bytes=$cur_tx_bytes

	# calculate the next rate for dl and ul
    cur_dl_rate=$( get_next_shaper_rate "$cur_dl_rate" "$min_dl_rate" "$max_dl_rate" "$rx_load" )
    cur_ul_rate=$( get_next_shaper_rate "$cur_ul_rate" "$min_ul_rate" "$max_ul_rate" "$tx_load" )

    if [ $enable_verbose_output -eq 1 ]; then
        printf "%s;%15.2f;%15.2f;%15.2f;%15.2f;%15.2f;%15.2f;\n" $( date "+%Y%m%dT%H%M%S.%N" ) $rx_load $tx_load $goal_deviation $cur_deviation $cur_dl_rate $cur_ul_rate
    fi
}

# set initial values for first run
get_mdev
cur_deviation=$mdevs;
cur_dl_rate=$min_dl_rate
cur_ul_rate=$min_ul_rate
# set the next different from the cur_XX_rates so that on the first round we are guaranteed to call tc
last_dl_rate=0
last_ul_rate=0
t_prev_bytes=$(date +%s.%N)
prev_rx_bytes=$(cat $rx_bytes_path)
prev_tx_bytes=$(cat $tx_bytes_path)
if [ $enable_verbose_output -eq 1 ]; then
    printf "%25s;%15s;%15s;%15s;%15s;%15s;%15s;\n" "log_time" "rx_load" "tx_load" "goal_deviation" "cur_deviation" "cur_dl_rate" "cur_ul_rate"
fi

# main loop runs every tick_duration seconds
while true
do
    t_start=$(date +%s.%N)
	get_mdev
    update_rates

	# only fire up tc if there are rates to change...
    if [ "$last_dl_rate" -ne "$cur_dl_rate" ] ; then
        #echo "tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit"
        tc qdisc change root dev ${dl_if} cake bandwidth ${cur_dl_rate}Kbit
    fi
    if [ "$last_ul_rate" -ne "$cur_ul_rate" ] ; then
        #echo "tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit"
        tc qdisc change root dev ${ul_if} cake bandwidth ${cur_ul_rate}Kbit
    fi

    # remember the last rates
	last_dl_rate=$cur_dl_rate
	last_ul_rate=$cur_ul_rate

    t_end=$(date +%s.%N)
	sleep_duration=$( call_awk "${tick_duration} - ${t_end} + ${t_start}" )
    if awk "BEGIN {exit !($sleep_duration > 0)}"; then
        sleep $sleep_duration
    fi
done
