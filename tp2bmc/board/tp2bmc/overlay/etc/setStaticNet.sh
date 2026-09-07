#!/bin/sh
# Optional static IP/MAC override, read from /etc/tpi.cfg (persisted) and
# /mnt/sdcard/tpi.ini (what a user drops on the SD card). With neither file
# present this script does nothing, which is the normal case.
#
# POSIX sh, not bash: the OTA image no longer ships bash. The logic is
# unchanged from the bash original -- only the constructs are. The `=~`
# regex tests became `case` patterns, and validate_ip's array split became
# `set --` under a dot IFS.

if [ -f /etc/tpi.cfg ]; then
    ip=$(cat /etc/tpi.cfg |grep ip|awk -F '=' '{print $2}')
    mac=$(cat /etc/tpi.cfg |grep mac|awk -F '=' '{print $2}')
fi
if [ -f /mnt/sdcard/tpi.ini ]; then
    inip=$(cat /mnt/sdcard/tpi.ini |grep ip|awk -F '=' '{print $2}')
    inmac=$(cat /mnt/sdcard/tpi.ini |grep mac|awk -F '=' '{print $2}')
    echo input ip:$inip
    echo input mac:$inmac
fi

# Four dot-separated decimal octets, each 0-255.
validate_ip() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac

  OIFS=$IFS
  IFS='.'
  # deliberate word split on the dots
  set -- $1
  IFS=$OIFS

  [ $# -eq 4 ] || return 1
  for octet in "$@"; do
    [ -n "$octet" ] || return 1
    [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

# Six colon-separated hex pairs.
validate_mac() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
    *) return 1 ;;
  esac
}

# 调用函数来验证MAC地址
if [ -n "${inmac:-}" ]; then
    if validate_mac "$inmac"; then
    if [ "${mac:-}" != "$inmac" ]; then
        mac=$inmac;
        if [ -n "${ip:-}" ]; then
            echo "ip=$ip" > /etc/tpi.cfg
        fi
        echo "mac=$inmac" >> /etc/tpi.cfg
    fi
    else
    echo "MAC $inmac error" > /mnt/sdcard/tpi_ini_err.log
    fi
fi

# 调用函数来验证IP地址
if [ -n "${inip:-}" ]; then
    if validate_ip "$inip"; then
    if [ "${ip:-}" != "$inip" ]; then
        ip=$inip;
        echo "ip=$inip" > /etc/tpi.cfg
        if [ -n "${mac:-}" ]; then
            echo "mac=$mac" >> /etc/tpi.cfg
        fi
    fi
    else
    echo "IP $inip error" >> /mnt/sdcard/tpi_ini_err.log
    fi
fi

# 如果不为空则设置mac
if [ -n "${mac:-}" ]; then
	ifconfig eth0 down
	echo set mac: $mac
	ifconfig eth0  hw ether $mac
	ifconfig eth0 up
fi
# 如果不为空则设置IP
if [ -n "${ip:-}" ]; then
	echo set ip: $ip
    udhcpc -r $ip -n
    if [ $? -eq 0 ]; then
        curip=$(ifconfig | grep 'inet addr:' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d ':' -f 2)
        if [ "$ip" != "$curip" ]; then
            ifconfig eth0 $ip up
        fi
    else
        ifconfig eth0 $ip up
    fi
fi

