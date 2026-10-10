# Embedded in package hooks so upgrades can stop older installed versions too.
rc_stop() {
  rc_job=${1:-com.altivecintelligence.rcloudd}
  rc_plist=${2:-/Library/LaunchDaemons/com.altivecintelligence.rcloudd.plist}
  rc_jobs=$(launchctl list) || return 1
  rc_pid=$(printf '%s\n' "$rc_jobs" | while read -r rc_p rc_status rc_label; do
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

# SpringBoard registers the foreground application separately from --daemon.
# Match its full bundle identity, not the shared executable name (which could
# also belong to recovery commands or an isolated test daemon).
rc_stop_ui() {
  rc_jobs=$(launchctl list) || return 1
  printf '%s\n' "$rc_jobs" | while read -r rc_pid rc_status rc_label; do
    case "$rc_label" in
      UIKitApplication:com.altivecintelligence.rcloud\[*\])
        case "$rc_pid" in
          -) continue ;;
          ''|*[!0-9]*) echo 'Unexpected rCloud GUI PID; refusing update.' >&2; exit 1 ;;
        esac
        kill -TERM "$rc_pid" 2>/dev/null || true
        rc_wait=0
        while kill -0 "$rc_pid" 2>/dev/null; do
          if [ "$rc_wait" -ge 30 ]; then
            echo 'rCloud is still running; close it and retry.' >&2
            exit 1
          fi
          sleep 1
          rc_wait=$((rc_wait + 1))
        done
        ;;
    esac
  done
}
rc_unregister() {
  # Old uicache versions may not support -u. postrm refreshes the full cache
  # after the bundle has actually disappeared in that case.
  su mobile -c 'uicache -u /Applications/rCloud.app' >/dev/null 2>&1 || true
}
