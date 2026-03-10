#!/usr/bin/env bash
#
# vm-health-check.sh
# Check VM health (CPU, Memory, Disk) on Ubuntu.
#
# Health rule (as requested):
# - If ANY metric is greater than 60% => NOT HEALTHY
# - Otherwise => HEALTHY
#
# Usage:
#   ./vm-health-check.sh            # prints health status
#   ./vm-health-check.sh explain    # prints health status + explanation
#   ./vm-health-check.sh --explain
#   ./vm-health-check.sh -e
#
set -uo pipefail

THRESHOLD=60

print_usage() {
  cat <<EOF
Usage: $0 [explain|--explain|-e]
Check VM health (CPU, Memory, Disk) on Ubuntu.
If any metric is above ${THRESHOLD}% the VM is declared NOT HEALTHY; otherwise HEALTHY.
EOF
}

# Parse args
EXPLAIN=false
for arg in "$@"; do
  case "$arg" in
    explain|--explain|-e) EXPLAIN=true ;; 
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; print_usage; exit 2 ;;
  esac
done

# Helper to compare floats: returns 0 if a > b else 1
float_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (a > b) exit 0; else exit 1 }'
}

# Get CPU usage (%)
# Parse top output to extract idle percentage, then 100 - idle
get_cpu_usage() {
  # top must be available on Ubuntu by default
  cpu_idle=$(top -bn1 2>/dev/null | grep -i "Cpu(s)" | sed -E 's/.*, *([0-9.]+)%* id.*/\1/')
  if [[ -z "$cpu_idle" ]]; then
    # fallback: use mpstat if available
    if command -v mpstat >/dev/null 2>&1; then
      cpu_idle=$(mpstat 1 1 | awk '/all/ {print 100 - $12}' | tail -n1)
      cpu_idle=$(printf "%.1f" "$cpu_idle")
    else
      echo "unable to determine CPU usage" >&2
      echo "0.0"
      return
    fi
  fi
  cpu_usage=$(awk -v idle="$cpu_idle" 'BEGIN { printf "%.1f", 100 - idle }')
  echo "$cpu_usage"
}

# Get Memory usage (%) using free
get_mem_usage() {
  if free_out=$(free 2>/dev/null); then
    mem_usage=$(awk '/^Mem:/ { printf "%.1f", $3/$2*100 }' <<<"$free_out")
    echo "$mem_usage"
  else
    echo "0.0"
  fi
}

# Get Disk usage (%) for root filesystem
get_disk_usage() {
  # Use POSIX df output
  disk_pct=$(df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
  if [[ -z "$disk_pct" ]]; then
    echo "0"
  else
    # Normalize to one decimal for consistency
    disk_usage=$(awk -v d="$disk_pct" 'BEGIN { printf "%.1f", d }')
    echo "$disk_usage"
  fi
}

cpu=$(get_cpu_usage)
mem=$(get_mem_usage)
disk=$(get_disk_usage)

# Determine health: if ANY > THRESHOLD => NOT HEALTHY
is_cpu_bad=false
is_mem_bad=false
is_disk_bad=false

if float_gt "$cpu" "$THRESHOLD"; then is_cpu_bad=true; fi
if float_gt "$mem" "$THRESHOLD"; then is_mem_bad=true; fi
if float_gt "$disk" "$THRESHOLD"; then is_disk_bad=true; fi

if $is_cpu_bad || $is_mem_bad || $is_disk_bad; then
  HEALTH="NOT HEALTHY"
else
  HEALTH="HEALTHY"
fi

# Output
echo "HEALTH: $HEALTH"

if $EXPLAIN ; then
  echo
  echo "Details (threshold = ${THRESHOLD}):"
  printf "  CPU usage:    %6s%%   %s\n" "$cpu" "$( $is_cpu_bad && echo 'OVER threshold' || echo 'OK' )"
  printf "  Memory usage: %6s%%   %s\n" "$mem" "$( $is_mem_bad && echo 'OVER threshold' || echo 'OK' )"
  printf "  Disk usage:   %6s%%   %s\n" "$disk" "$( $is_disk_bad && echo 'OVER threshold' || echo 'OK' )"
  echo

  if $is_cpu_bad ; then
    echo "Reason: CPU usage is above ${THRESHOLD}%. Consider checking running processes (e.g., 'top' or 'ps aux --sort=-%cpu'), services, excessive load, or scaling CPU resources."
  fi
  if $is_mem_bad ; then
    echo "Reason: Memory usage is above ${THRESHOLD}%. Consider checking memory-hungry processes ('ps aux --sort=-%mem'), caching, or adding more memory / tuning services."
  fi
  if $is_disk_bad ; then
    echo "Reason: Root filesystem usage is above ${THRESHOLD}%. Consider cleaning logs, removing unused packages, or increasing disk capacity. Use 'du -sh /*' or 'ncdu' to find large directories."
  fi

  if ! $is_cpu_bad && ! $is_mem_bad && ! $is_disk_bad ; then
    echo "All metrics are below ${THRESHOLD}%. VM is healthy."
  fi
fi

# Exit code: 0 for healthy, 2 for not healthy
if [[ "$HEALTH" == "HEALTHY" ]]; then
  exit 0
else
  exit 2
fi
