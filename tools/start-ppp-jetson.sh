#!/bin/sh
# Run on the Jetson, from lolv/, AFTER the board-side start-ppp.sh has
# already started pppd (that terminal should look silent/garbled now --
# that's correct). Kills litex_term to free the port, starts the Jetson
# side of the same PPP link, and verifies it comes up.

echo "== killing any litex_term holding the serial port =="
pkill -f litex_term 2>/dev/null
sleep 1
echo

echo "== confirming /dev/ttyACM0 is free =="
sudo fuser /dev/ttyACM0 2>&1
echo

echo "== starting pppd (local 192.168.7.2, peer 192.168.7.1) =="
sudo pppd /dev/ttyACM0 115200 192.168.7.2:192.168.7.1 \
  local noauth nocrtscts nodetach persist maxfail 3 \
  > /tmp/ppp-jetson.log 2>&1 &

PPPD_PID=$!
echo "  pppd started, pid $PPPD_PID, logging to /tmp/ppp-jetson.log"
echo

echo "== waiting up to 15s for ppp0 to come up =="
i=0
while [ $i -lt 15 ]; do
  if ip addr show ppp0 >/dev/null 2>&1; then
    echo "  ppp0 is up:"
    ip addr show ppp0
    break
  fi
  sleep 1
  i=$((i+1))
done

if ! ip addr show ppp0 >/dev/null 2>&1; then
  echo "  ppp0 did NOT come up within 15s. Recent log:"
  tail -30 /tmp/ppp-jetson.log
else
  echo
  echo "== pinging the board =="
  ping -c 3 192.168.7.1
fi

echo
echo "done (pppd pid $PPPD_PID left running -- kill it with: sudo kill $PPPD_PID)"
