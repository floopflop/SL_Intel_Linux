#!/usr/bin/python3 -I
"""Parse the OV02C10 module EEPROM dump (camdbg eeprom output) of the Surface Laptop 7.
Layout found on this unit (16-bit addressed 24C64):
  0x000  13-byte header 01 06 00 00 0a 02 db 59 c0 67 0b 07 05
  0x00d  8 planes x 7 rows x 11 cols, 8 bit: coarse shading, 0 at the centre, ~90-134 at corners
         (channel order Gr, R, B, Gb per light; 2 lights). Encoding not needed: region 2 is used.
  0x275  misc: 8 u16 values, checksum, module info, 55 aa marker, 3 radial profiles (18 u16, Q7),
         optical centres (960, 545), residual grids ...
  0xa20  16-byte header, then 02 11 0d = version 2, grid 17 x 13, then planes of 17x13 u16:
         relative sensor response, 1023 at the optical centre; gain = 1023 / value.
         Plane order R, Gr, Gb, B per light, 2-byte checksum after each light; 2 lights.
Usage as a tool: eeprom_nvm.py <dump.txt>  (prints a summary)"""
import re, struct, sys
W, H = 17, 13

def load(path):
    txt = open(path).read()
    return bytes(int(x, 16) for x in re.findall(r'0x([0-9a-f]{2})', txt))

def parse(b):
    out = {"size": len(b), "header": b[:13]}
    planes8 = []
    for p in range(8):
        base = 13 + p * 77
        planes8.append([[b[base + r * 11 + c] for c in range(11)] for r in range(7)])
    out["coarse"] = planes8
    i = 0x6e5
    while i < len(b) and b[i] == 0xff:
        i += 1
    out["region2"] = i
    hdr = b[i:i + 16]; ver, w, h = b[i + 16], b[i + 17], b[i + 18]
    out["r2header"] = hdr; out["r2version"] = ver
    assert (w, h) == (W, H), f"unexpected NVM grid {w}x{h}"
    d0 = i + 19
    names = ["r", "gr", "gb", "b"]
    planes = []; lights = []; pos = d0
    # each light: 4 planes of 17x13 u16, then a 2-byte checksum
    while pos + 4 * W * H * 2 <= len(b):
        light = []
        for c in range(4):
            g = struct.unpack_from(f'<{W * H}H', b, pos + c * W * H * 2)
            if max(g) > 1023 or min(g) == 0:
                light = None
                break
            light.append(g)
        if light is None:
            break
        planes += light
        lights.append({names[c]: light[c] for c in range(4)})
        pos += 4 * W * H * 2 + 2
    out["nvm_planes"] = planes
    out["lights"] = lights
    out["tail"] = b[pos - 2: pos + 30]
    return out

def gains(plane):
    """Per-node gain of a 17x13 response plane (1023 at the centre)."""
    return [1023.0 / v if v else 1.0 for v in plane]

if __name__ == "__main__":
    e = parse(load(sys.argv[1]))
    print(f"dump {e['size']} bytes; region 2 at 0x{e['region2']:04x}, version {e['r2version']}, "
          f"{len(e['nvm_planes'])} planes = {len(e['lights'])} complete lights")
    print("region 2 header:", e["r2header"].hex(" "))
    for li, light in enumerate(e["lights"]):
        print(f"light {li}:")
        for name, plane in light.items():
            g = gains(plane)
            corners = [g[0], g[W - 1], g[(H - 1) * W], g[H * W - 1]]
            print(f"  {name:2s}: centre {plane[(H // 2) * W + W // 2]:4d}, corner gains " +
                  " ".join(f"{c:.2f}" for c in corners) + f", min response {min(plane)}")
    if e["tail"]:
        print("bytes after the planes:", e["tail"].hex(" "))
