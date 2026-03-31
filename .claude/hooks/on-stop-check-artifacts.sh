#!/usr/bin/env bash
# Stop hook: reminder to check artifacts if a phase run is in progress
STATUS_FILES=(runs/*/status.json)

for f in "${STATUS_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    STATUS=$(python3 -c "import json,sys; d=json.load(open('$f')); print(d.get('status',''))" 2>/dev/null)
    if [[ "$STATUS" == "in_progress" ]]; then
      echo "Notice: phase run in progress at $f — status=in_progress"
    fi
  fi
done

exit 0
