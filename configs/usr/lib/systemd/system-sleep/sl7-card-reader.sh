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
# So "pre" resumes the reader and holds it active. Resuming takes about 1.2 s: the link fails to
# retrain here too, and the kernel removes the reader and detects it again, which is why the code
# looks the device up afresh instead of keeping its path. "post" returns it to "auto"; the reader
# that the kernel detects at resume starts out that way in any case.
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
      sleep 0.5                                  # the kernel now removes the reader and detects it again
      i=0; until { d=$(reader) && active "$d"; } || [ $i -ge 25 ]; do sleep 0.2; i=$((i + 1)); done
    fi
    d=$(reader) && echo on > "$d/power/control" 2>/dev/null   # keep it active until the system is down
    ;;
  post)
    d=$(reader) && echo auto > "$d/power/control" 2>/dev/null
    ;;
esac
exit 0
