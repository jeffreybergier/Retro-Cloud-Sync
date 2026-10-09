# Embedded in package hooks so upgrades can stop older installed versions too.
rc_stop() {
  rc_job=${1:-com.altivecintelligence.rcloudd}
  rc_plist=${2:-/Library/LaunchDaemons/com.altivecintelligence.rcloudd.plist}
  rc_pid=$(launchctl list | while read rc_p rc_status rc_label; do
    if [ "$rc_label" = "$rc_job" ]; then printf '%s' "$rc_p"; fi
  done)
  case "$rc_pid" in
    '') return 0 ;;
    -) ;;
    *[!0-9]*) echo 'Unexpected rCloud launchd PID; refusing update.' >&2; return 1 ;;
    *)
      kill -TERM "$rc_pid" 2>/dev/null || true
      rc_wait=0
      while kill -0 "$rc_pid" 2>/dev/null; do
        if [ "$rc_wait" -ge 30 ]; then
          echo 'rCloud has not stopped; resolve any pending prompt and retry.' >&2
          return 1
        fi
        sleep 1
        rc_wait=$((rc_wait + 1))
      done
      ;;
  esac
  launchctl unload "$rc_plist"
}
