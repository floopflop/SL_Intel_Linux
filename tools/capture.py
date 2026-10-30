#!/usr/bin/python3 -I
"""Record raw evdev events from the touchpad devices while prompting gestures.
Run as root:  sudo ./capture.py [outfile]
Output: JSON lines, one per event, plus phase markers.
Each instruction is shown with a countdown (CAPTURE_GRACE seconds, default 4) before its timer starts."""
import os, sys, struct, select, time, json, glob

EV_FMT = "llHHi"           # struct input_event on 64-bit
EV_SIZE = struct.calcsize(EV_FMT)

def find_devices():
    devs = {}
    cur = {}
    for line in open("/proc/bus/input/devices"):
        if line.startswith("N:"):
            cur = {"name": line.split('"')[1]}
        elif line.startswith("H:") and cur:
            ev = [h for h in line.split("=")[1].split() if h.startswith("event")]
            if ev and ("0C9F" in cur["name"]):
                devs["/dev/input/" + ev[0]] = cur["name"]
    return devs

PHASES = [
    ("rest",        "Keep your hands OFF the touchpad.", 3),
    ("one-slow",    "ONE finger: slide slowly around the pad, light touch, don't lift.", 6),
    ("one-normal",  "ONE finger: move the cursor around normally, lift and re-touch a few times.", 6),
    ("two-scroll",  "TWO fingers: scroll up and down continuously.", 6),
    ("three-swipe", "THREE fingers: swipe left/right and up/down.", 6),
    ("hold-two",    "Rest TWO fingers on the pad and hold them STILL.", 4),
    ("taps",        "Tap with ONE finger, about once per second.", 5),
    ("pinch",       "TWO fingers: pinch in and out.", 5),
]

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "captures/touchpad-%s.jsonl" % time.strftime("%Y%m%d-%H%M%S")
    devs = find_devices()
    if not devs:
        sys.exit("no 045E:0C9F devices found")
    fds = {}
    for path, name in devs.items():
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        fds[fd] = (path, name)
    print("Recording:", *("  %s = %s" % (p, n) for p, n in devs.items()), sep="\n")
    print("Output:", out, "\n")
    f = open(out, "w")
    f.write(json.dumps({"marker": "devices", "devices": devs}) + "\n")
    t0 = time.monotonic()
    GRACE = float(os.environ.get("CAPTURE_GRACE", "4"))   # seconds to read the instruction before recording

    def pump(until, record):
        """Read events until the deadline; write them only while recording."""
        while True:
            left = until - time.monotonic()
            if left <= 0:
                break
            r, _, _ = select.select(list(fds), [], [], min(left, 0.25))
            for fd in r:
                try:
                    data = os.read(fd, EV_SIZE * 64)
                except BlockingIOError:
                    continue
                if not record:
                    continue
                for i in range(0, len(data) - EV_SIZE + 1, EV_SIZE):
                    sec, usec, typ, code, val = struct.unpack(EV_FMT, data[i:i + EV_SIZE])
                    f.write(json.dumps({"d": fds[fd][0], "t": sec + usec / 1e6, "ty": typ, "c": code, "v": val}) + "\n")

    for phase, text, secs in PHASES:
        print("\n>>> NEXT: %s" % text); sys.stdout.flush()
        # grace period: show the instruction, count down, then start the timed recording
        for n in range(int(GRACE), 0, -1):
            print("    starting in %d..." % n, end="\r"); sys.stdout.flush()
            pump(time.monotonic() + 1.0, record=False)
        print("    GO  (%d s)              " % secs); sys.stdout.flush()
        f.write(json.dumps({"marker": "phase", "phase": phase, "t": time.monotonic() - t0}) + "\n")
        pump(time.monotonic() + secs, record=True)
        print("    done."); sys.stdout.flush()
    f.write(json.dumps({"marker": "end", "t": time.monotonic() - t0}) + "\n")
    f.close()
    os.chmod(out, 0o644)
    print("\nDone. Saved", out)

if __name__ == "__main__":
    main()
