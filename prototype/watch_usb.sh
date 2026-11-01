#!/bin/bash
# Beobachtet N s lang den IORegistry-Teilbaum des CZUR (nur Lesen) und meldet jede Änderung.
snap() { ioreg -r -c IOUSBHostDevice -l -w0 -n "QHD CAMERA" 2>/dev/null | grep -v -E "sessionID|IOGeneralInterest|retain|busy" ; }
HID() { ioreg -r -c IOHIDDevice -l -w0 2>/dev/null | grep -i -E '"Product"|"VendorID"|"ProductID"|"Manufacturer"' | grep -i -B1 -A2 -E "czur|1276|fic" ; }
prev=$(snap | md5); prevh=$(HID | md5); echo "$(date +%T) Start (Gerät: $(snap | wc -l | tr -d ' ') Zeilen)"
end=$((SECONDS+${1:-45}))
while [ $SECONDS -lt $end ]; do
  cur=$(snap | md5); curh=$(HID | md5)
  [ "$cur" != "$prev" ] && echo "$(date +%T) USB-Teilbaum geändert" && prev=$cur
  [ "$curh" != "$prevh" ] && echo "$(date +%T) HID-Gerät geändert" && prevh=$curh
  sleep 0.2
done
echo "$(date +%T) Ende"
