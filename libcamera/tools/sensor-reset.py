#!/usr/bin/python3 -I
"""Set the OV02C10 sensor to minimum exposure and unity gain (a 'dark start'), so that the next
camera session has to ramp its auto exposure up. Run as root. Usage: sensor-reset.py [exposure] [gain_code]"""
import fcntl, struct, sys, glob, os, ctypes
EXPOSURE = int(sys.argv[1]) if len(sys.argv) > 1 else 4
GAIN = int(sys.argv[2]) if len(sys.argv) > 2 else 16          # code 16 = 1.0x
V4L2_CID_EXPOSURE, V4L2_CID_ANALOGUE_GAIN = 0x00980911, 0x009e0903
VIDIOC_S_EXT_CTRLS = 0xc0205648
dev = None
for p in glob.glob("/dev/v4l-subdev*"):
    name = open(f"/sys/class/video4linux/{os.path.basename(p)}/name").read()
    if "ov02c10" in name:
        dev = p
if not dev:
    sys.exit("ov02c10 sub-device not found")
fd = os.open(dev, os.O_RDWR)
class Ctrl(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("size", ctypes.c_uint32), ("reserved2", ctypes.c_uint32), ("value", ctypes.c_int32), ("pad", ctypes.c_int32)]
class Ctrls(ctypes.Structure):
    _fields_ = [("which", ctypes.c_uint32), ("count", ctypes.c_uint32), ("error_idx", ctypes.c_uint32), ("request_fd", ctypes.c_int32), ("reserved", ctypes.c_uint32), ("controls", ctypes.c_void_p)]
for cid, val in ((V4L2_CID_EXPOSURE, EXPOSURE), (V4L2_CID_ANALOGUE_GAIN, GAIN)):
    c = Ctrl(cid, 0, 0, val, 0); arr = (Ctrl * 1)(c)
    cs = Ctrls(0, 1, 0, 0, 0, ctypes.cast(arr, ctypes.c_void_p))
    fcntl.ioctl(fd, VIDIOC_S_EXT_CTRLS, cs)
print(f"{dev}: exposure {EXPOSURE}, gain code {GAIN}")
