# Surface Laptop 7 (Intel) on Linux

Fixes for the Surface Laptop for Business 7th Edition with Intel (Lunar Lake, ACPI id MSHW0551,
model 2107) on a stock distribution kernel. Developed and tested on Fedora 44 with kernel 7.2.x;
the kernel part fetches the sources for whatever kernel you run and should work on any
distribution with 7.2 or newer. One command installs everything:

```
git clone https://github.com/floopflop/SL_Intel_Linux.git && cd SL_Intel_Linux
sudo ./install.sh all          # then reboot
./install.sh status            # afterwards: everything should say patched / active / present
```

Before you start:

- You need an external USB keyboard for the installation and until the first reboot after
  `install.sh all`: the internal keyboard hangs off the Surface Aggregator Module, which the stock
  kernel does not know on this model. Wi-Fi and the touchpad work out of the box. If `git` is
  missing, `sudo dnf install git` first.
- Network access is required: the kernel sources come from kernel.org, iptsd from GitHub and the
  libcamera source package from Fedora. The libcamera rebuild is the slow part (tens of minutes).
- Secure Boot can stay on. DKMS signs the modules with a machine owner key (MOK). With Secure Boot
  on, `install.sh` asks you to choose a one-time password, and the next boot shows the blue MOK
  manager for about ten seconds: press a key before it times out, then Enroll MOK, Continue, Yes,
  enter that password, Reboot. If it times out the request is dropped; run
  `sudo mokutil --import /var/lib/dkms/mok.pub` and reboot again. Until this is done the patched
  modules do not load (`./install.sh status` says so). With Secure Boot off nothing is asked;
  `sudo ./install.sh kernel` prints how to enrol the key if you want to turn Secure Boot on later.

## What is fixed

| Area | Problem on a stock kernel | Fix | Where |
|---|---|---|---|
| Battery, AC, fan, keyboard, light sensor | Not present: upstream's MSHW0551 node group is for the Snapdragon model, where they are not SAM devices | Intel node group with battery/AC, performance profile with fan, SAM keyboard and sensors | `surface_aggregator_registry` module |
| Speakers | No sound: the BIOS declares a second RT1320 amplifier that never attaches, and the SoundWire card setup waits for it forever | Skip peripherals that have not enumerated after 1.5 s, renumber the real amp for UCM | `snd-soc-sdw-utils` module |
| Webcam frame rate | 18.8 fps and a wrong pixel rate: the sensor runs from a 12 MHz clock, the driver only knows 19.2 MHz | Accept 12 MHz and scale both PLL multipliers (400 to 640) | `ov02c10` module |
| Webcam trails | Flickering horizontal line fragments behind moving objects: IPU7 capture DMA does not snoop the CPU caches and the driver flushes buffers only once | Flush each buffer before it is queued and when it is dequeued | `intel-ipu7-isys` module |
| Webcam picture | Flat, uncalibrated software ISP: vignetting, poor white balance, slow and bright exposure, noise, mains flicker bands | Lens shading from the module EEPROM, shading-aware AWB, fast exposure control with frame-length extension, anti-banding, spatial + temporal denoise, YUYV output for V4L2 apps | `libcamera/` patch + tuning |
| Touchpad | Blinks at the end of gestures, twitchy cursor after resume, two close fingers merged, scroll too fast, no palm rejection | Tracker-level lift grace, evdev fuzz (libinput hysteresis), cluster merging in the detector, motion scaling, thresholds, libinput palm quirk | `iptsd/` patches + `configs/` |
| Keyboard dead at login screen | SAM keyboard appears ~8 s into boot, while the greeter starts | Load `surface_aggregator_registry` and `surface_hid` early | `configs/etc/modules-load.d` |
| Keyboard, battery, power button dead for a whole boot | `surface_serial_hub: failed to setup IRQ`: when the SAM driver loads before the Lunar Lake pin controller (it does once it sits in the initramfs), its wake-GPIO lookup fails and the driver gives up instead of deferring | modprobe softdep loading `pinctrl_intel_platform` first | `configs/etc/modprobe.d` |
| Camera gone after a DKMS build | dracut copies every out-of-tree module and its dependencies into the initramfs; the IPU7 driver then probes there without its firmware and never recovers | dracut omit list for the camera and audio modules | `configs/etc/dracut.conf.d` |
| Power button does not wake | Wakeup disabled on the serial hub the keyboard sits behind | udev rule enabling wakeup | `configs/etc/udev` |
| Suspend aborts, Bluetooth dead | `btintel_pcie` fails to enter D2 | Unload before sleep, reload after | `configs/usr/lib/systemd/system-sleep` |
| Interrupt storm | SAM GPE 0xAB fires continuously | `acpi_mask_gpe=0xAB` on the kernel command line | `install.sh configs` |
| Camera pickers | 30+ raw IPU7 V4L2 nodes listed next to the real camera | WirePlumber rule hiding them | `configs/etc/wireplumber` |

Not fixed: the SAM UART interrupt storm that can hang suspend (linux-surface issue #2263).

## How it works

**Kernel modules.** `kernel/fetch-sources.sh` downloads the handful of driver files the four
modules need from kernel.org, for exactly the kernel version being built for (`uname -r`, override
with `KERNEL_TAG=vX.Y.Z` if your distribution's version string does not map to a stable tag).
`kernel/port-patches.py` applies the fixes as anchored edits, so they survive line drift between
releases and fail loudly if the code they patch has changed. The modules are built out of tree and
installed in `/lib/modules/<kernel>/updates/` (or `extra/`, where Fedora's DKMS puts them; a
`depmod.d` file makes both take precedence over the distribution's copies). With `dkms` installed
(recommended, `install.sh deps` installs it on Fedora), `install.sh kernel` registers the tree
with DKMS so every kernel update rebuilds the modules automatically (network access is needed at
that time). Without DKMS, run `sudo ./install.sh kernel` after each kernel update; those modules are
unsigned, so that path needs Secure Boot off. Nothing in the
running kernel is modified; `uninstall.sh` returns to the distribution's modules.

Two side effects of out-of-tree modules are handled by `configs/`: dracut (and Fedora's DKMS, which
rebuilds every initramfs after each build) copies the modules and their dependencies into the
initramfs. There the SAM stack would load before the pin controller that provides its wake GPIO
and fail for the whole boot (`configs/etc/modprobe.d/surface-sam.conf` orders the two), and the
IPU7 camera driver would probe without its firmware (`configs/etc/dracut.conf.d/` keeps the camera
and audio modules out). `install.sh kernel` and `install.sh configs` install these files before the
initramfs is rebuilt, and rebuild it themselves when DKMS does not. On Fedora, installing `dkms`
can also pull in the newest kernel's `kernel-core` without its `kernel-modules` (through the
`kernel-devel-matched` dependency); `install.sh deps` completes such a kernel.

**Touchpad.** `iptsd/build.sh` clones the alex-lentz fork of iptsd (it carries the Sensel haptic
touchpad support this laptop needs), applies the eight patches in `iptsd/patches/`, and builds it;
`install.sh iptsd` installs it to `/usr/local` together with the tuned configuration
(`configs/etc/iptsd.d/`), the libinput palm quirk and a service that restarts iptsd after resume
(the touchpad firmware falls back to its native mode after sleep). GNOME users may also want
click-method `fingers` and tap-to-click.

**Webcam.** `libcamera/libcamera-0.7.2-sl7.patch` is a patch against libcamera 0.7.2 (the version
in Fedora 44). On Fedora, `libcamera/fedora-rpm.sh` rebuilds the distribution's source package with
it and `install.sh libcamera` installs and version-locks the result, installs the tuning file
`libcamera/tuning/ov02c10.yaml` and restarts WirePlumber. On other distributions
`libcamera/source-build.sh` builds 0.7.2 from source with the same options and the installer copies
it over the system libcamera (pin the package afterwards). GNOME Camera, Firefox and other PipeWire
clients use the camera directly; V4L2-only applications (Zoom) need `pipewire-v4l2`:
`tools/zoom-camera.sh` launches Zoom through it.

## Tuning knobs

`/etc/iptsd.d/99-surface-laptop-7-touchpad.conf`: `ActivationThreshold`/`DeactivationThreshold`
(24/20), `PeakSuppressionRadius`/`Factor` (2 / 0.3, keeps close fingers apart), `LiftGraceMs` (50),
`PositionSmoothing` (0.5), `TwoFingerMotionScale` (0.45, scroll/pinch speed), `MultiFingerMotionScale`
(0.6, three-finger gestures), `HysteresisMm` (0.25). Restart with `sudo systemctl restart 'iptsd@*'`.

`/usr/share/libcamera/ipa/simple/ov02c10.yaml`, section `Agc`: `exposureValue` (brightness in
stops, -0.5), `flickerPeriod` (8333 us for 60 Hz mains, 10000 for 50 Hz, 0 off), `longExposureGain`
(gain above which the frame rate drops for longer exposures, 12), `hysteresis` (0.1). Section
`Denoise`: `temporalStrength` / `temporalChromaStrength` (0.5 / 0.75; lower if motion looks
smeared, 0 to disable), `temporalMotionLow` / `High`, the `chroma` and `luma` spatial curves.
Close and reopen the camera application after a change. `LIBCAMERA_SOFTISP_NOTEMPORAL=1` in the
environment disables the temporal filter for comparisons.

## Troubleshooting

`./install.sh status` reports most of these. Kernel messages: `journalctl -kb`.

- **Internal keyboard, battery, AC and power button all missing for a boot**, with
  `surface_serial_hub serial0-0: error -EINVAL: failed to setup IRQ` in the log: the SAM driver
  probed before the pin controller. `sudo ./install.sh configs` installs the softdep and rebuilds
  the initramfs; reboot. (An external keyboard works meanwhile.)
- **Camera missing**, with `intel-ipu7 ... Direct firmware load for intel/ipu/ipu7_fw.bin failed`
  early in the log: the IPU7 driver was loaded from the initramfs. Same fix as above.
- **Modules fail with `Unknown symbol`** and `status` reports a kernel without `kernel-modules`:
  the kernel is half installed (Fedora, see above). `sudo ./install.sh deps` completes it, or
  `sudo dnf install kernel-<ver> kernel-modules-<ver> kernel-modules-extra-<ver>`; then reboot.
- **`version magic` errors**: modules built for another kernel were copied into this kernel's tree.
  `sudo ./install.sh kernel` removes stale copies and rebuilds.
- **DKMS did not build for a new kernel** (`dkms status` lacks the kernel): the build at kernel
  installation failed (no network, or kernel.org had no tag yet). `surface-laptop-7-intel-dkms.service`
  retries once the network is up at the next boot; `sudo ./install.sh kernel` builds right away.
- **Secure Boot rejects the modules** (`module verification failed` plus a load failure): the MOK key
  is not enrolled, so redo the enrolment above. `sudo ./install.sh status` shows which kernel keyring
  holds the key. Fedora's kernel accepts it from the platform keyring; a kernel that only consults
  the machine keyring needs the MOK certificate to be a CA certificate (`basicConstraints=CA:TRUE`,
  `keyUsage=keyCertSign`), so regenerate and re-enrol it that way.

## Diagnostics

`tools/`: `tpcheck.sh` (root; which device feeds libinput), `capture2.sh` (root; raw heatmap +
evdev recording with prompted gestures), `metrics.py` and `hmstats.py` (analyse an
`iptsd-replay` run of such a recording: `iptsd/src/build/src/iptsd-replay <raw.bin>`).
`libcamera/tools/`: `snap.py` (save a frame as PNG), `aetrace.py` (per-frame exposure, gain,
frame duration, brightness, banding metric), `noise.py` and `tnoise.py` (spatial and temporal
noise), `latency.py` (capture-to-delivery), `sensor-reset.py` (force a dark start),
`camdbg` (root; sensor registers, module EEPROM dump), `eeprom_nvm.py` and
`gen-ov02c10-tuning.py` (regenerate the tuning for your own module: the EEPROM dump comes from
`camdbg eeprom 8192`; the colour matrices come from the `OV02C10_MSHW0550_LNL.aiqb` file in the
Windows driver store, `ov02c10_extension.inf_amd64_*`, which this repository does not ship).
All camera tools run `cam` and need the camera to be free (close camera apps first).
`tools/report.sh` (ideally as root) collects everything about an installation into one text
file: `sudo ./tools/report.sh > report.txt`. Attach it when reporting a problem.

## License

GPL-2.0-or-later (see `LICENSE`). The kernel patches in `kernel/` are derived from the Linux kernel
and are GPL-2.0-only like the files they modify; the iptsd patches follow iptsd (GPL-2.0-or-later);
`libcamera/libcamera-0.7.2-sl7.patch` modifies libcamera and is LGPL-2.1-or-later like libcamera
itself. Copyright (C) 2026 the contributors to this repository.

## Details

`docs/engineering-log.md` is the day-by-day record with measurements, dead ends and the reasoning
behind each value above. The SAM and audio fixes come from nierdal's bring-up report in linux-surface issue #1710
(https://github.com/linux-surface/linux-surface/issues/1710), which is not redistributed here. Credits: nierdal (issue #1710 fixes), alex-lentz
(iptsd fork with Sensel touchpad support), Christian Schaller (software ISP lens shading port).
The libcamera and iptsd changes were developed with the help of an AI coding assistant (Claude)
and reviewed and tested on this hardware.
