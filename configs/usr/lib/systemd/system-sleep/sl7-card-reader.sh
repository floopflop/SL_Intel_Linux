#!/bin/sh
# Surface Laptop 7 15" (Intel): wake the microSD reader (Realtek RTS5261, behind root port 00:1c.4)
# just before the system suspends, and hand it back to runtime power management afterwards.
#
# Left alone, the reader powers down about 10 s after it was last used (D3cold, link dropped). While
# the machine is awake that is what it should do: with the reader kept active the processor package
# never reaches C10 and an idle machine draws 1 W more (2.85 against 1.81 W). But a system suspend
# that finds the reader powered down resumes it in order to suspend it, the link does not retrain
# ("pcieport 0000:00:1c.4: retraining failed", "pciehp: Slot(4): Card not present", 3 s in device
# suspend), and the package then stays in C2 for the whole sleep: no S0ix, about 1.5 W, a third of
# the battery in a night. A reader that is active when the suspend starts goes down cleanly.
#
# So "pre" resumes the reader and holds it active. Resuming takes a second or more: the link fails
# to retrain here too, and the kernel removes the reader and detects it again. "post" returns it to
# "auto"; the reader that the kernel detects at resume starts out that way in any case.
DEVS=${SL7_PCI_DEVICES:-/sys/bus/pci/devices}

reader() {   # the reader's sysfs directory, if it is on the bus
  for r in "$DEVS"/*; do
    [ "$(cat "$r/vendor" 2>/dev/null)" = 0x10ec ] && [ "$(cat "$r/device" 2>/dev/null)" = 0x5261 ] && { echo "$r"; return 0; }
  done
  return 1
}
active() { [ -e "$1/driver" ] && [ "$(cat "$1/power/runtime_status" 2>/dev/null)" = active ]; }

case "$1" in
  pre)
    d=$(reader) || exit 0                        # not on the bus: nothing to resume, the suspend is clean
    if ! active "$d"; then
      echo on > "$d/power/control" 2>/dev/null   # returns once the resume has been tried
      # The kernel now removes the reader and detects it again at the same address: 20 ms later in
      # five suspends out of seven, 6.7 s later in the other two. Wait for the new device to be
      # bound and active, for up to 12 s, so that the suspend does not start while it is missing.
      sleep 0.5
      i=0; until active "$d" || [ $i -ge 60 ]; do sleep 0.2; i=$((i + 1)); done
    fi
    [ -e "$d/power/control" ] && echo on > "$d/power/control" 2>/dev/null   # keep it active until the system is down
    ;;
  post)
    d=$(reader) && echo auto > "$d/power/control" 2>/dev/null
    ;;
esac
exit 0
