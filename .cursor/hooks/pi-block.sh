#!/bin/bash
B=true;SF="";D="$PWD"
while [ -n "$D" ] && [ "$D" != "/" ]; do
  [ -f "$D/.pi/pi-block-state.json" ] && { SF="$D/.pi/pi-block-state.json"; break; }
  D="$(dirname "$D")"
done
[ -n "$SF" ] && { X=$(grep -o '"blocked":[^,}]*' "$SF" 2>/dev/null|head -1|sed 's/.*: *//');[ "$X" = "false" ]&&B=false; }
[ "$B" = "true" ] && exit 2
exit 0
