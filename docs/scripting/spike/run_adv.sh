#!/bin/bash
# usage: run_adv.sh <mode> [timeout]
cd /workspace/scriptshot-spike
G=/workspace/tools/Godot_v4.7.2-stable_linux.x86_64
MODE=$1; TO=${2:-30}
for t in $(grep -oE '^\s+"[a-z_]+": \[' bench/adversarial.gd | sed 's/[": \[]//g'); do
  start=$(date +%s%N)
  out=$(timeout $TO $G --headless --path . -- adversarial $t $MODE 2>&1)
  rc=$?
  line=$(echo "$out" | grep -E "^ADV " | head -1)
  el=$(( ($(date +%s%N) - start) / 1000000000 ))
  if [ -z "$line" ]; then
    if [ $rc -eq 124 ]; then echo "ADV test=$t mode=$MODE outcome=HUNG (killed by external timeout ${TO}s; game frozen) heartbeat=NONE"; 
    else echo "ADV test=$t mode=$MODE outcome=PROCESS_ENDED rc=$rc after ${el}s (game process terminated before heartbeat) $(echo "$out" | grep -iE 'ADV_ERROR|SCRIPT ERROR|crash|Segmentation' | head -2 | tr '\n' ' ')"; fi
  else echo "$line"; fi
done
