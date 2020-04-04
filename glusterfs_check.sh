#!/bin/bash
echo "Running glusterfs check"

# define some variables
PIDOF="/bin/pidof"
MY_HOSTNAME=`hostname -f`
GLUSTER="/usr/sbin/gluster"
PEERSTATUS="peer status"
VOLLIST="volume list"
VOLINFO="volume info"
VOLHEAL1="volume heal"
VOLHEAL2="info"
GEOREP1="volume geo-replication"
GEOREP2="status detail"
GLUSTERFS_DATA=/var/local/gluster_check
description=""

critical_alert_send () {
	echo "$1"
	##Send critical alert
	exit 0
}

# check for commands
for cmd in $PIDOF $GLUSTER; do
    if [ ! -x "$cmd" ]; then
        description="UNKNOWN - $cmd not found"
        echo "$description"
	critical_alert_send "$description"
    fi
done

# check for glusterd (management daemon)
if ! $PIDOF glusterd &>/dev/null; then
    description="CRITICAL - glusterd management daemon not running"
    echo "$description"
    critical_alert_send "$description"
fi

# check for glusterfsd (brick daemon)
if ! $PIDOF glusterfsd &>/dev/null; then
    description="CRITICAL - glusterfsd daemon not running"
    echo "$description"
    critical_alert_send "$description"
fi

##Gather data during first run to compare on every check
##Incase of any changes to glusterfs cluster: Node addition, geo-replication enable/disable
##Delete the file /var/local/gluster_check, run the script again after the changes are done.
if [ ! -f $GLUSTERFS_DATA ]; then

    ##Get number of peers
    PEERCOUNT=`$GLUSTER $PEERSTATUS | grep "Number of Peers" | awk '{print $4}'`
    echo "PEERCOUNT=$PEERCOUNT" >> $GLUSTERFS_DATA
    for vol in $($GLUSTER $VOLLIST); do

	##Get Brick count
	var="BRICKCOUNT_${vol}"
	eval "BRICKCOUNT_${vol}=`$GLUSTER $VOLINFO $vol| grep "Number of Bricks:" | awk '{print $NF}'`"
        echo "BRICKCOUNT_${vol}=${!var}" >> $GLUSTERFS_DATA

	##Get the first node active in geo-replication
	##As running status check on geo-replication locks the Bricks
	## and doesn't allow other nodes to perform status check, 
	## the geo-replication status check will be added to first active node.
	var="GEOREP_ACTIVE_${vol}"
        eval "GEOREP_ACTIVE_${vol}=`$GLUSTER $GEOREP1 $vol $GEOREP2 | sed '1,3d' | awk '($7 ~ /Active/) && ($13 == 0) {print $1}' | sort | head -n1 | awk "/${MY_HOSTNAME}/"|wc -l`"
        if [ ${!var} -eq 1 ];then
		echo "GEOREP_ACTIVE_${vol}=${!var}" >> $GLUSTERFS_DATA
	fi
    done
fi

##Unset variables before loading them
unset "PEERCOUNT" "BRICKCOUNT_${vol}" "GEOREP_ACTIVE_${vol}"
source $GLUSTERFS_DATA

#Check peer count
CURR_PEERCOUNT=`$GLUSTER $PEERSTATUS | grep "Number of Peers" | awk '{print $4}'`
if [ $CURR_PEERCOUNT -ne $PEERCOUNT ]; then
    description="CRITICAL - glusterfs peer count mismatch"
    echo "$description"
    critical_alert_send "$description"
fi

# get peer status
for peer in $($GLUSTER $PEERSTATUS | grep '^Hostname: ' | awk '{print $2}'); do
    state=
    state=$($GLUSTER $PEERSTATUS | grep -A 2 "^Hostname: $peer$" | grep '^State: ' | sed -nre 's/.* \(([[:graph:]]+)\)$/\1/p')
    if [ "$state" != "Connected" ]; then
	description="CRITICAL - $peer peer status $state"
	echo "$description"
        critical_alert_send "$description"
    fi
done

# get volume status and brick count
for vol in $($GLUSTER $VOLLIST); do
    curr_var="CURR_BRICKCOUNT_${vol}"
    var="BRICKCOUNT_${vol}"
    eval "CURR_BRICKCOUNT_${vol}=`$GLUSTER $VOLINFO $vol| grep "Number of Bricks:" | awk '{print $NF}'`"
    if [ ${!curr_var} -ne ${!var} ]; then
    	description="CRITICAL - glusterfs brick count mismatch for $vol"
    	echo "$description"
    	critical_alert_send "$description"
    fi
    entries=
    for entries in $($GLUSTER $VOLHEAL1 $vol $VOLHEAL2 | grep '^Number of entries: ' | awk '{print $4}'); do
        if [ "$entries" -gt 0 ]; then
	    description="CRITICAL - $vol volume info entries $entries"
	    echo "$description"
    	    critical_alert_send "$description"
        fi
    done
done

##Geo-replication check
for vol in $($GLUSTER $VOLLIST); do
	geovar="GEOREP_ACTIVE_${vol}"
	if [ ! -z ${!geovar} ];then
		##Compare number of bricks to nodes in geo-replication
		GEOREPCOUNT=`$GLUSTER $GEOREP1 $vol $GEOREP2 | sed '1,3d' | wc -l`
		var="BRICKCOUNT_${vol}"
		if [ $GEOREPCOUNT -ne ${!var} ]; then
	    		description="CRITICAL - glusterfs geo-replication nodes count mismatch"
	    		echo "$description"
	    		critical_alert_send "$description"
		fi
		##Check if any nodes have status other than Active/Passive
		GEOREPSTATUS=`$GLUSTER $GEOREP1 $vol $GEOREP2 | sed '1,3d' | awk '{ if ($7 !~ /(Active|Passive)/) print }' | wc -l`
		if [ $GEOREPSTATUS -gt 0 ]; then
	                description="CRITICAL - glusterfs geo-replication nodes status"
	                echo "$description"
	                critical_alert_send "$description"
	        fi
		##Check for any failures on active nodes.
		GEOREPFAILURE=`$GLUSTER $GEOREP1 $vol $GEOREP2 | sed '1,3d' | awk '($7 ~ /Active/) && ($13 != 0)' | wc -l`
	        if [ $GEOREPFAILURE -gt 0 ]; then
	                description="CRITICAL - glusterfs geo-replication failures"
	                echo "$description"
	                critical_alert_send "$description"
	        fi

	fi
done

##Send ok/successful alert
echo "Glusterfs healthcheck successful"
