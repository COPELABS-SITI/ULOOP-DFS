#!/bin/sh
#
# Copyright (c) 2012. ULHT - SITI.
#
# Description:
#
# Creates N virtual APs 
# (rev.2.2)
#
# Usage: ./uloop-create-aps.sh [number of APs to create]

. /etc/functions.sh
append DRIVERS "mac80211"

#The functions start_net() and set_wifi_up() are used by mac80211.sh to enable the interface.

start_net() {(
	local iface="$1"
	local config="$2"
	local vifmac="$3"

	[ -f "/var/run/$iface.pid" ] && kill "$(cat /var/run/${iface}.pid)" 2>/dev/null
	[ -z "$config" ] || {
		include /lib/network
		scan_interfaces
		setup_interface "$iface" "$config" "" "$vifmac"
	}
)}

set_wifi_up() {
	local cfg="$1"
	local ifname="$2"
	uci_set_state wireless "$cfg" up 1
	uci_set_state wireless "$cfg" ifname "$ifname"
}

#Find the device and the interfaces. Return: "device"

scan_wifi() {
	local cfgfile="$1"
	DEVICES=
	config_cb() {
		config_get TYPE "$CONFIG_SECTION" TYPE
		case "$TYPE" in
			wifi-device)
				append DEVICES "$CONFIG_SECTION"
				config_set "$CONFIG_SECTION" vifs ""
			;;
			wifi-iface)
				config_get device "$CONFIG_SECTION" device
				config_get vifs "$device" vifs 
				append vifs "$CONFIG_SECTION"
				config_set "$device" vifs "$vifs"
			;;
		esac
	}
	config_load "${cfgfile:-wireless}"
}

#The brigde_interface() is used by mac80211 to brigde the interface with the network.

bridge_interface() {(
	local cfg="$1"
	[ -z "$cfg" ] && return 0

	include /lib/network
	scan_interfaces

	config_get iftype "$cfg" type
	[ "$iftype" = bridge ] && config_get "$cfg" ifname
)}

#Find the configuration for a given virtual interface

find_net_config() {(
	local vif="$1"
	local cfg
	local ifname

	config_get cfg "$vif" network

	[ -z "$cfg" ] && {
		include /lib/network
		scan_interfaces

		config_get ifname "$vif" ifname

		cfg="$(find_config "$ifname")"
	}
	[ -z "$cfg" ] && return 0
	echo "$cfg"
)}

#Set the hwmode of a given device (b/g/bg/a/n)

wifi_fixup_hwmode() {
	local device="$1"
	local default="$2"
	local hwmode hwmode_11n

	config_get channel "$device" channel
	config_get hwmode "$device" hwmode
	case "$hwmode" in
		11bg) hwmode=bg;;
		11a) hwmode=a;;
		11b) hwmode=b;;
		11g) hwmode=g;;
		11n*)
			hwmode_11n="${hwmode##11n}"
			case "$hwmode_11n" in
				a|g) ;;
				default) hwmode_11n="$default"
			esac
			config_set "$device" hwmode_11n "$hwmode_11n"
		;;
		*)
			hwmode=
			if [ "${channel:-0}" -gt 0 ]; then 
				if [ "${channel:-0}" -gt 14 ]; then
					hwmode=a
				else
					hwmode=g
				fi
			else
				hwmode="$default"
			fi
		;;
	esac
	config_set "$device" hwmode "$hwmode"
}


create_ap() {

local a=1
local option1=`expr $1 + 1`
local AlreadyExist=1
local iFace_number=1
local b=0
while [ $a -lt $option1 ]
do
   #Find the device and the interfaces. Return: "device"
   scan_wifi
   #Find the mac80211 of the given device.
   find_mac80211_phy "$device"
   echo "DEVICE: "$device""
   #Get the physical interface of the device
   config_get phy "$device" phy

   while [ $AlreadyExist ]
   do
	name="wlan${phy#phy}-$iFace_number"	
	ifconfig $name >/dev/null 2>/dev/null
	if [ $? -eq 1 ]
	then
		AlreadyExist=0
		break
	else
		iFace_number=`expr $iFace_number + 1`
		AlreadyExist=1
	fi
	
   done
   
   #UCI Commands to modify the Wireless configuration file

   uci add wireless wifi-iface >/dev/null
   uci set wireless.@wifi-iface[-1].device=radio0
   uci set wireless.@wifi-iface[-1].encryption=none
   uci set wireless.@wifi-iface[-1].mode=ap
   uci set wireless.@wifi-iface[-1].ssid=OpenWRTest$iFace_number
   uci set wireless.@wifi-iface[-1].network=lan
   uci set wireless.@wifi-iface[-1].name=$name
   uci set wireless.@wifi-iface[-1].uloop=1
   uci commit wireless 

   echo "Creating the virtual interface..."

   #Create the virtual interface with managed type.    

   iw "$phy" interface add "$name" type managed
	
   #Gets the MAC address of the device.
   config_get macaddr $device macaddr
   #This function gives a MAC address based on the MAC address of the device.
   mac="$(mac80211_generate_mac $iFace_number $macaddr)"
   #Assign the new MAC address to the virtual interface.
   ifconfig "$name" hw ether $mac
   echo "MAC: $mac"
   #This steps have to be done again, because a new interface have been added.
   scan_wifi		  
   find_mac80211_phy "$device"
   
   wifi_fixup_hwmode "$device" "g"
   #Get the physical interface of the device
   config_get phy "$device" phy
   #Get the virtual interfaces of the device
   config_get vifs "$device" vifs
   echo "Existing interfaces:"
   echo $vifs
   local i=0
   for vif in $vifs; do
	   config_get ifname "$vif" ifname
	   config_get nome "$vif" name
   	   if [ "$nome" = "$name" ]
	   then
		ifname="$name"
		b=$i
		#Setting the name of the virtual interface and is mac address
		config_set "$vif" ifname "$ifname"		
		config_set "$vif" macaddr "$mac"
		#Creating the hostapd configuration file
		mac80211_hostapd_setup_bss "$phy" "$vif" "$ifname"		
		#Get the mode of the virtual interface. it must show "AP".			
		config_get mode "$vif" mode
		echo "New Interface Mode: "$mode""
		#Enables the virtual interface
		mac80211_start_vif "$vif" "$ifname"
		echo "Interface Created: "$ifname" -> "$vif""
		break
	   fi
	   i=`expr $i + 1`	   
   done
   #Call the hostapd to run the access point.
   hostapd -P /var/run/wifi-"$phy".pid -B /var/run/hostapd-"$name"-"$phy".conf

   if [ $a -eq $option1 ]
   then
      break
   fi
   a=`expr $a + 1`
done

}

set_wifi_down() {
	local cfg="$1"
	local wdev="$2"
	local vifs vif vifstr
	local i=0
	config_get vifs "$cfg" vifs
	for vif in $vifs; do
		config_get nome "$vif" name
		if [ "$nome" = "$wdev" ]
	   	then 
			echo "VIF: "$vif""
			echo "i: "$i""
			uci delete wireless.@wifi-iface[$i]
   			uci commit wireless
			break
		fi
	 	i=`expr $i + 1`	    
	done
}

remove_ap() {
   scan_wifi
   #local i=0
   local wdev="$1"
   echo "Removing: "$1" on "$device""
   find_mac80211_phy "$device" || return 0
   config_get phy "$device" phy
   set_wifi_down "$device" "$wdev"
   echo "Searching the pid: "$pid""
   for pid in `pidof hostapd`; do
	if [ $(grep -c "$wdev" /proc/$pid/cmdline) -ne 0 ] 
	then				
		kill $pid
		rm  /var/run/hostapd-"$wdev"-"$phy".conf
	fi
   done
   echo "Delete wdev: "$pid""
   ifconfig "$wdev" down
   iw dev "$wdev" del	
}

set_uloop_down() {
	local cfg="$1"
	local wdev="$2"
	local vifs vif vifstr
	local i=0
	config_get vifs "$cfg" vifs
	for vif in $vifs; do
		config_get uloop "$vif" uloop
		if [ "$uloop" -eq 1 ]
	   	then 
			echo "VIF: "$vif""
			echo "i: "$i""
			config_get name "$vif" name
			uci delete wireless.@wifi-iface[$i]
   			uci commit wireless
			rm  /var/run/hostapd-"$name"-"$phy".conf
			ifconfig "$name" down
   			iw dev "$name" del
		else
	 		i=`expr $i + 1`	  
		fi  
	done
}


remove_uloop_ap() {
   scan_wifi
   local i=0
   local wdev="wlan0"
   find_mac80211_phy "$device" || return 0
   config_get phy "$device" phy
   echo "From PHY: "$phy""
   set_uloop_down "$device" "$wdev"
   echo "Searching the pid: "$pid""
   for pid in `pidof hostapd`; do
	if [ $(grep -c "$wdev" /proc/$pid/cmdline) -ne 0 ] 
	then				
		kill $pid
	fi
   done
   echo "Delete wdev: "$pid""
}

include /lib/wifi
include /lib/network

case "$1" in
	down) case "$2" in
		uloop) remove_uloop_ap ;;
		*) remove_ap "$2" ;;
	      esac;;
	*) create_ap "$1";;
esac

