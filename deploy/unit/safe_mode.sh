#!/bin/sh
# safe_mode.sh: the deploy tool's boot-loop guard (deploy/README.md, "Safe
# mode"). While /var/opt/mgu-deploy/safe-mode exists, our tools' units do
# not start: their drop-in zz-mgu-deploy-limits.conf has
# ConditionPathExists=! on it and orders them after this guard.
#
#   safe_mode.sh mark   at each shutdown through the NodeStateManager
#                       (var-opt-ro.service, drop-in
#                       40-mgu-deploy-safe-mode.conf), before /var/opt goes
#                       read-only: how this start ends
#   safe_mode.sh boot   at boot, before our tools' units
#                       (mgu-deploy-safe-mode.service): counts how the start
#                       before ended, and turns safe mode on at the
#                       THRESHOLD-th failed start in a row
#   safe_mode.sh up     then: a start that stays up RESET_UP_S clears the
#                       count
#
# A failed start: it ended in a restart recmgr or crashhandler asked for
# within FAILED_UP_S of the start, and none of our tools asked for it
# (restart-requested, written by them before they ask, names the start).
# The mark takes a restart as theirs on either record of it: the
# restartInfo.xml each writes when it asks (written in this start), or a
# row recmgr added to its crash statistics (recmgr_stats.db, table Crash,
# whose keys only grow) since this start's boot step; recmgr's startup,
# some 10 s into a start, deletes its restartInfo.xml, also one of that
# same start. A shutdown without either record (a switch-off, the HMI's or
# the Store's restart) clears the count once the start was up FAILED_UP_S;
# earlier, it could be a restart whose records were lost, and neither
# counts nor clears. A start up RESET_UP_S clears it too. A start without a
# mark (a power cut, a reset that skipped var-opt-ro.service), a mark of
# another start, or a crash restart after FAILED_UP_S neither counts nor
# clears. A state file that is missing or does not read as written counts
# nothing.
#
# Files in /var/opt/mgu-deploy, each written whole (renamed into place):
#   last-shutdown       "<boot id> crash|normal <uptime s> [recmgr] [crashhandler] [recmgr_stats]"
#   safe-mode-count     "<failed starts in a row> <boot id this guard last counted in>"
#   safe-mode-crashes   "<boot id> <recmgr's last crash key at its boot step>"
#   restart-requested   "<boot id>": a restart our tools asked for in that start
#   safe-mode           {"at": "<UTC time>", "reason": "<why>"}
#
# Always exits 0, and writes nothing without /var/opt/mgu-deploy.
VAR_OPT=${MGU_DEPLOY_VAR_OPT:-/var/opt}
DIR=$VAR_OPT/mgu-deploy
SIN=$VAR_OPT/public/sin
BOOT_ID=${MGU_DEPLOY_BOOT_ID:-/proc/sys/kernel/random/boot_id}
UPTIME=${MGU_DEPLOY_PROC:-/proc}/uptime
PROC_STAT=${MGU_DEPLOY_PROC_STAT:-/proc/stat}
THRESHOLD=4
FAILED_UP_S=120
RESET_UP_S=300
# the longest a read of recmgr's statistics may take
STATS_WAIT_S=2

LAST=$DIR/last-shutdown
COUNT=$DIR/safe-mode-count
CRASHES=$DIR/safe-mode-crashes
REQUESTED=$DIR/restart-requested
FLAG=$DIR/safe-mode
STATS=$SIN/recmgr/recmgr_stats.db

say() { echo "safe mode: $*"; }

# A file's first line, or nothing.
first_line() { [ -f "$1" ] && head -n 1 "$1" 2>/dev/null; }

# Whole seconds of uptime; empty when unreadable.
uptime_s() {
  u=$(cut -d. -f1 "$UPTIME" 2>/dev/null | cut -d' ' -f1)
  case "$u" in ''|*[!0-9]*) return ;; esac
  echo "$u"
}

is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }

# put <file> <text>: the text whole into the file
put() { printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"; }

# recmgr's last crash key (0 with none), read within STATS_WAIT_S; empty
# without its statistics or sqlite3, or when they cannot be read.
crash_key() {
  [ -f "$STATS" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
  out=$DIR/.crash-key.$$
  sqlite3 "$STATS" 'PRAGMA busy_timeout=500; SELECT ifnull(max(CrashKey), 0) FROM Crash;' > "$out" 2>/dev/null &
  pid=$!
  ( sleep "$STATS_WAIT_S"; kill "$pid" 2>/dev/null ) &
  timer=$!
  wait "$pid"
  status=$?
  kill "$timer" 2>/dev/null
  k=$(tail -n 1 "$out" 2>/dev/null)
  rm -f "$out"
  [ "$status" -eq 0 ] && is_count "$k" && echo "$k"
  return 0
}

[ -d "$DIR" ] || exit 0
boot=$(first_line "$BOOT_ID")
case "$boot" in ''|*[!0-9A-Za-z-]*) exit 0 ;; esac

case "$1" in
mark)
  up=$(uptime_s)
  [ -n "$up" ] || exit 0
  now=$(date +%s)
  since=$(sed -n 's/^btime //p' "$PROC_STAT" 2>/dev/null)
  case "$since" in ''|*[!0-9]*) since=$((now - up)) ;; esac
  who=
  for m in recmgr crashhandler; do
    # written in this start: not before its btime, not after now, a second
    # of slack each way (busybox's stat -c, BSD's -f)
    t=$(stat -c %Y "$SIN/$m/restartInfo.xml" 2>/dev/null || stat -f %m "$SIN/$m/restartInfo.xml" 2>/dev/null) || continue
    case "$t" in ''|*[!0-9]*) continue ;; esac
    [ "$t" -ge $((since - 1)) ] && [ "$t" -le $((now + 1)) ] && who="$who $m"
  done
  # shellcheck disable=SC2046 # two words
  set -- $(first_line "$CRASHES")
  if [ "$1" = "$boot" ] && is_count "$2"; then
    k=$(crash_key)
    [ -n "$k" ] && [ "$k" -gt "$2" ] && who="$who recmgr_stats"
  fi
  if [ -n "$who" ]; then put "$LAST" "$boot crash $up$who"; else put "$LAST" "$boot normal $up"; fi
  ;;
boot)
  # shellcheck disable=SC2046 # two words
  set -- $(first_line "$COUNT")
  count=$1 seen=$2
  # a count only below the threshold is one this guard wrote
  if ! is_count "$count" || [ "$count" -ge "$THRESHOLD" ] || [ -z "$seen" ]; then count=0 seen=; fi
  [ "$seen" = "$boot" ] && exit 0
  verdict=
  # shellcheck disable=SC2046 # fields
  set -- $(first_line "$LAST")
  if [ -n "$seen" ] && [ "$1" = "$seen" ] && is_count "$3"; then
    kind=$2 up=$3
    shift 3
    if [ "$(first_line "$REQUESTED")" = "$seen" ]; then
      verdict=clear why="a restart our tools asked for"
    elif [ "$kind" = normal ] && [ "$up" -ge "$FAILED_UP_S" ]; then
      verdict=clear why="ended normally"
    elif [ "$kind" = crash ] && [ "$up" -lt "$FAILED_UP_S" ]; then
      verdict=count why="a restart after a crash ($*) at ${up} s"
    elif [ "$kind" = crash ] && [ "$up" -ge "$RESET_UP_S" ]; then
      verdict=clear why="up ${up} s"
    fi
  fi
  case "$verdict" in
    count) count=$((count + 1)) ;;
    clear) count=0 ;;
  esac
  if [ "$count" -ge "$THRESHOLD" ]; then
    count=0
    if [ ! -e "$FLAG" ]; then
      put "$FLAG" "{\"at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"reason\": \"$THRESHOLD starts in a row ended in a restart after a crash within $FAILED_UP_S s\"}"
      say "on: $THRESHOLD starts in a row ended in a restart after a crash within $FAILED_UP_S s; our tools stay off"
    fi
  fi
  put "$COUNT" "$count $boot"
  k=$(crash_key)
  if [ -n "$k" ]; then put "$CRASHES" "$boot $k"; else rm -f "$CRASHES"; fi
  [ -n "$verdict" ] && say "the last start: $why; $count failed in a row"
  [ -e "$FLAG" ] && say "on: our tools' units do not start"
  ;;
up)
  up=$(uptime_s)
  [ -n "$up" ] && [ "$up" -lt "$RESET_UP_S" ] && sleep $((RESET_UP_S - up))
  # shellcheck disable=SC2046 # two words
  set -- $(first_line "$COUNT")
  if [ "$2" = "$boot" ] && [ "$1" != 0 ] && is_count "$1"; then
    put "$COUNT" "0 $boot"
    say "up ${RESET_UP_S} s: the count starts again"
  fi
  ;;
esac
exit 0
