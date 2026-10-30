#!/bin/bash
# Launch Zoom with PipeWire's V4L2 bridge so it can see the libcamera camera.
# The Zoom RPM reads V4L2 devices directly; on this laptop those are raw Bayer
# nodes it cannot use. pw-v4l2 (package pipewire-v4l2) presents the PipeWire
# camera node as a virtual V4L2 device instead.
if command -v pw-v4l2 >/dev/null 2>&1; then
	exec pw-v4l2 /usr/bin/zoom "$@"
fi
notify-send "Zoom camera bridge missing" "Install it with: sudo dnf install pipewire-v4l2" 2>/dev/null
exec /usr/bin/zoom "$@"
