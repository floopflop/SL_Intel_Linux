#!/bin/sh
# Surface Laptop 7 (Intel): suspend bookkeeping, for the questions the journal cannot answer.
# It only records; nothing here changes how the machine sleeps.
#
# pre:  one line with a time stamp, synced to disk before the machine sleeps. The kernel's
#       messages of a suspend cycle reach the journal only after a successful resume, and the
#       journal's last lines before it are not reliably on disk, so a suspend that never comes
#       back (a hang, or the battery running flat) leaves "PM: suspend entry" at best. Here a
#       "pre" without a "post" is such a suspend, whatever the journal kept.
# post: how long the machine was away (slept), how much of that the SoC spent in its deep idle
#       state (s0ix; a small share means a high drain), the battery, and what woke it: the wake
#       interrupt (irq) and the wakeup sources and ACPI GPEs that fired meanwhile (fired).
# The pre line also lists the Thunderbolt devices (tb) and the network interfaces with their
# drivers (net), as context for a suspend that does not come back.
# `./install.sh status` summarises the log; README, Troubleshooting, explains the fields.
#
# SELinux (Fedora): systemd-sleep runs in systemd_sleep_t, which may not create or open files in
# /var/log. Executing a hook labelled bin_t from it transitions to unconfined_service_t, so this
# works as long as the file has the directory's label (install(1) and cp give it that; a file
# moved here from a home directory keeps user_home_t: restorecon it).
LOG=${SL7_SUSPEND_LOG:-/var/log/sl7-suspend.log}
RUN=${SL7_SUSPEND_RUN:-/run}
SNAP=$RUN/sl7-suspend.counters
T0=$RUN/sl7-suspend.t0

# first line of a file, "?" when it cannot be read (sysfs files that return ENODATA or EINVAL)
val() { v=; { read -r v < "$1"; } 2>/dev/null; printf '%s' "${v:-?}"; }

bat() {   # charge and state of the system battery, e.g. 87%/Charging
  for p in /sys/class/power_supply/*; do
    [ "$(val "$p/type")" = Battery ] || continue
    [ "$(val "$p/scope")" = Device ] && continue          # a mouse or headset battery
    st=$(val "$p/status"); [ "$st" = "Not charging" ] && st=NotCharging
    printf '%s%%/%s' "$(val "$p/capacity")" "$st"; return
  done
  printf '?'
}

tb() {    # Thunderbolt/USB4 devices behind the host router (0-3 is a device; 0-0:3.1 is a retimer)
  c=0
  for d in /sys/bus/thunderbolt/devices/[0-9]*-[1-9]*; do
    [ -e "$d" ] || continue
    case ${d##*/} in *:*|*.*) ;; *) c=$((c + 1));; esac
  done
  printf '%s' "$c"
}

net() {   # interface:driver for every interface backed by a device
  s=
  for n in /sys/class/net/*; do
    [ -e "$n/device/driver" ] || continue
    d=$(readlink "$n/device/driver"); s="$s${s:+,}${n##*/}:${d##*/}"
  done
  printf '%s' "${s:-none}"
}

counters() {   # "name<TAB>count" for every wakeup source and ACPI GPE that has fired since boot
  for w in /sys/class/wakeup/wakeup*; do
    { read -r n < "$w/name" && read -r c < "$w/event_count"; } 2>/dev/null || continue
    [ "$c" = 0 ] || printf '%s\t%s\n' "$n" "$c"
  done
  for g in /sys/firmware/acpi/interrupts/gpe[0-9A-F][0-9A-F] /sys/firmware/acpi/interrupts/sci; do
    { read -r c rest < "$g"; } 2>/dev/null || continue
    [ "$c" = 0 ] || printf '%s\t%s\n' "${g##*/}" "$c"
  done
}

case "$1" in
  pre)
    date +%s > "$T0" 2>/dev/null
    counters > "$SNAP" 2>/dev/null
    printf '%s pre %s kern=%s bat=%s tb=%s net=%s\n' \
      "$(date -Is)" "${2:-?}" "$(uname -r)" "$(bat)" "$(tb)" "$(net)" >> "$LOG" 2>/dev/null
    sync "$LOG" 2>/dev/null || sync                       # on disk before the machine can hang
    ;;
  post)
    slept=?; t0=$(val "$T0")
    case $t0 in ''|*[!0-9]*) ;; *) slept=$(($(date +%s) - t0));; esac
    hw=$(val /sys/power/suspend_stats/last_hw_sleep)      # microseconds in S0ix in this cycle
    case $hw in ''|*[!0-9]*) hw=?;; *) hw=$((hw / 1000000));; esac
    irq=$(val /sys/power/pm_wakeup_irq)                   # ENODATA when the PM core saw no wake IRQ
    case $irq in ''|*[!0-9]*) irq=?;; *)
      irq="$irq($(awk -v i="$irq:" '$1 == i { for (k = 2; k <= NF; k++) if ($k !~ /^[0-9]+$/) {
        for (j = k; j <= NF; j++) printf "%s%s", (j > k ? "_" : ""), $j; exit } }' /proc/interrupts))";;
    esac
    fired=?                                               # no snapshot from "pre": unknown
    if [ -s "$SNAP" ]; then
      counters > "$SNAP.now" 2>/dev/null
      fired=$(awk -F'\t' 'FILENAME == ARGV[1] { pre[$1] += $2; next } { now[$1] += $2 }
        END { for (k in now) if (now[k] > pre[k]) printf "%s%s+%d", (n++ ? "," : ""), k, now[k] - pre[k] }' \
        "$SNAP" "$SNAP.now" 2>/dev/null)
      fired=${fired:-none}
    fi
    printf '%s post %s slept=%ss s0ix=%ss bat=%s irq=%s fired=%s\n' \
      "$(date -Is)" "${2:-?}" "$slept" "$hw" "$(bat)" "$irq" "$fired" >> "$LOG" 2>/dev/null
    rm -f "$SNAP" "$SNAP.now" "$T0" 2>/dev/null
    # two lines per suspend: the kept tail is months of use
    if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
      tail -n 4000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
    ;;
esac
exit 0
