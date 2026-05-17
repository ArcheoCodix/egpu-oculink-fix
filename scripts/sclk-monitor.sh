#!/bin/bash
# Monitor SCLK, GPU load, and pp_features DS_GFXCLK state for eGPU crash investigation
# Usage: ./sclk-monitor.sh [card] [interval_sec]
# Logs to ~/sclk-monitor-YYYYMMDD-HHMMSS.log

CARD=${1:-card1}
INTERVAL=${2:-5}
LOGFILE="$HOME/sclk-monitor-$(date +%Y%m%d-%H%M%S).log"
DEV="/sys/class/drm/$CARD/device"
HWMON=$(ls "$DEV/hwmon/" 2>/dev/null | head -1)

echo "Logging to: $LOGFILE"
echo "Card: $CARD | Interval: ${INTERVAL}s | Ctrl+C to stop"
echo ""

{
  echo "# sclk-monitor start $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# card=$CARD interval=${INTERVAL}s"
  echo "# pp_features at start:"
  cat "$DEV/pp_features" 2>/dev/null | grep -E "(features|DS_GFXCLK|GFXOFF)"
  echo "# perf_level at start: $(cat $DEV/power_dpm_force_performance_level 2>/dev/null)"
  echo "#"
  printf "%-20s %-12s %-10s %-8s %-12s\n" "timestamp" "sclk_mhz" "mclk_mhz" "gpu_pct" "perf_level"
  echo "# ---"

  while true; do
    TS=$(date '+%Y-%m-%d %H:%M:%S')

    SCLK_HZ=$(cat "$DEV/hwmon/$HWMON/freq1_input" 2>/dev/null || echo 0)
    MCLK_HZ=$(cat "$DEV/hwmon/$HWMON/freq2_input" 2>/dev/null || echo 0)
    SCLK_MHZ=$(( SCLK_HZ / 1000000 ))
    MCLK_MHZ=$(( MCLK_HZ / 1000000 ))
    GPU_PCT=$(cat "$DEV/gpu_busy_percent" 2>/dev/null || echo "?")
    PERF=$(cat "$DEV/power_dpm_force_performance_level" 2>/dev/null || echo "?")

    printf "%-20s %-12s %-10s %-8s %-12s\n" "$TS" "$SCLK_MHZ" "$MCLK_MHZ" "$GPU_PCT" "$PERF"

    sleep "$INTERVAL"
  done
} | tee "$LOGFILE"
