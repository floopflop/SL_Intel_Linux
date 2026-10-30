#!/bin/sh
# Surface Laptop 7 / Intel BE201: btintel_pcie fails to enter D2 ("Timeout on
# alive interrupt"), which ABORTS every system suspend with -16 (the machine
# then retries in a loop with the lid closed, draining the battery) and leaves
# hci0 dead until a PCI remove/rescan. Workaround: unload the driver before
# sleep, reload it on resume. Drop the hook once the kernel driver is fixed.
case "$1" in
    pre)
        modprobe -r btintel_pcie 2>/dev/null || true
        ;;
    post)
        modprobe btintel_pcie 2>/dev/null || true
        ;;
esac
exit 0
