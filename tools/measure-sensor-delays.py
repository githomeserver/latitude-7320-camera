#!/usr/bin/env python3
"""Measure the OV5675's exposure and gain application delays.

libcamera's camera_sensor_properties.cpp has an ov5675 entry with an empty
sensorDelays, so libcamera guesses. The delay is simply how many frames pass
between writing a control and the frame that reflects it, which is directly
observable: stream raw Bayer straight off the sensor, step the control at a
known frame, and see which frame changes.

Deliberately NOT going through libcamera. libcamera applies controls using the
very delay model we are trying to measure, so it would be circular. This talks
to the V4L2 subdev and the ISYS capture node directly.

Run as root, with v4l2-relayd stopped (measure-sensor-delays.sh does both).
"""

import ctypes
import fcntl
import mmap
import os
import re
import statistics
import subprocess
import sys

# --------------------------------------------------------------------- ioctl
_IOC_WRITE, _IOC_READ = 1, 2


def _ioc(d, t, nr, size):
    return (d << 30) | (size << 16) | (ord(t) << 8) | nr


class Timeval(ctypes.Structure):
    _fields_ = [("tv_sec", ctypes.c_long), ("tv_usec", ctypes.c_long)]


class Timecode(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                ("frames", ctypes.c_uint8), ("seconds", ctypes.c_uint8),
                ("minutes", ctypes.c_uint8), ("hours", ctypes.c_uint8),
                ("userbits", ctypes.c_uint8 * 4)]


class PixFormat(ctypes.Structure):
    _fields_ = [("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("pixelformat", ctypes.c_uint32), ("field", ctypes.c_uint32),
                ("bytesperline", ctypes.c_uint32), ("sizeimage", ctypes.c_uint32),
                ("colorspace", ctypes.c_uint32), ("priv", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("enc", ctypes.c_uint32),
                ("quantization", ctypes.c_uint32), ("xfer_func", ctypes.c_uint32)]


class Format(ctypes.Structure):
    class _U(ctypes.Union):
        # The real union also holds v4l2_window, which contains a pointer, so
        # it is 8-byte aligned. Without _align here ctypes aligns to 4 and
        # sizeof comes out 204 instead of 208, which encodes the wrong ioctl
        # number and the kernel answers ENOTTY.
        _fields_ = [("pix", PixFormat), ("raw", ctypes.c_uint8 * 200),
                    ("_align", ctypes.c_uint64)]
    _fields_ = [("type", ctypes.c_uint32), ("fmt", _U)]


class RequestBuffers(ctypes.Structure):
    _fields_ = [("count", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("memory", ctypes.c_uint32), ("capabilities", ctypes.c_uint32),
                ("flags", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 3)]


class Buffer(ctypes.Structure):
    class _M(ctypes.Union):
        _fields_ = [("offset", ctypes.c_uint32), ("userptr", ctypes.c_ulong),
                    ("planes", ctypes.c_void_p), ("fd", ctypes.c_int32)]
    _fields_ = [("index", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("bytesused", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                ("field", ctypes.c_uint32), ("timestamp", Timeval),
                ("timecode", Timecode), ("sequence", ctypes.c_uint32),
                ("memory", ctypes.c_uint32), ("m", _M),
                ("length", ctypes.c_uint32), ("reserved2", ctypes.c_uint32),
                ("request_fd", ctypes.c_int32)]


VIDIOC_S_FMT = _ioc(_IOC_WRITE | _IOC_READ, "V", 5, ctypes.sizeof(Format))
VIDIOC_G_FMT = _ioc(_IOC_WRITE | _IOC_READ, "V", 4, ctypes.sizeof(Format))
VIDIOC_REQBUFS = _ioc(_IOC_WRITE | _IOC_READ, "V", 8, ctypes.sizeof(RequestBuffers))
VIDIOC_QUERYBUF = _ioc(_IOC_WRITE | _IOC_READ, "V", 9, ctypes.sizeof(Buffer))
VIDIOC_QBUF = _ioc(_IOC_WRITE | _IOC_READ, "V", 15, ctypes.sizeof(Buffer))
VIDIOC_DQBUF = _ioc(_IOC_WRITE | _IOC_READ, "V", 17, ctypes.sizeof(Buffer))
VIDIOC_STREAMON = _ioc(_IOC_WRITE, "V", 18, 4)
VIDIOC_STREAMOFF = _ioc(_IOC_WRITE, "V", 19, 4)

class ExtControl(ctypes.Structure):
    _pack_ = 1
    # Under _pack_ = 1 the MSVC and GCC layouts are identical (every field sits
    # at a consecutive offset), so pinning this only silences 3.14's warning
    # about the implicit default; it does not change the layout.
    if sys.version_info >= (3, 14):
        _layout_ = "ms"

    class _V(ctypes.Union):
        _fields_ = [("value", ctypes.c_int32), ("value64", ctypes.c_int64),
                    ("ptr", ctypes.c_void_p)]
    _fields_ = [("id", ctypes.c_uint32), ("size", ctypes.c_uint32),
                ("reserved2", ctypes.c_uint32 * 1), ("v", _V)]


class ExtControls(ctypes.Structure):
    _fields_ = [("which", ctypes.c_uint32), ("count", ctypes.c_uint32),
                ("error_idx", ctypes.c_uint32), ("request_fd", ctypes.c_int32),
                ("reserved", ctypes.c_uint32 * 1),
                ("controls", ctypes.POINTER(ExtControl))]


VIDIOC_G_EXT_CTRLS = _ioc(_IOC_WRITE | _IOC_READ, "V", 71, ctypes.sizeof(ExtControls))
VIDIOC_S_EXT_CTRLS = _ioc(_IOC_WRITE | _IOC_READ, "V", 72, ctypes.sizeof(ExtControls))

CID_EXPOSURE = 0x00980911
CID_ANALOGUE_GAIN = 0x009E0903
CID_VBLANK = 0x009E0901

BUF_TYPE_VIDEO_CAPTURE = 1
MEMORY_MMAP = 1
NBUFS = 8

# Check the encodings against the values the kernel actually uses on x86-64.
# Getting a struct size wrong silently produces an ioctl number nothing
# implements, which surfaces as a confusing ENOTTY rather than a size error.
_EXPECTED = {
    "VIDIOC_G_FMT": (VIDIOC_G_FMT, 0xC0D05604),
    "VIDIOC_S_FMT": (VIDIOC_S_FMT, 0xC0D05605),
    "VIDIOC_REQBUFS": (VIDIOC_REQBUFS, 0xC0145608),
    "VIDIOC_QUERYBUF": (VIDIOC_QUERYBUF, 0xC0585609),
    "VIDIOC_QBUF": (VIDIOC_QBUF, 0xC058560F),
    "VIDIOC_DQBUF": (VIDIOC_DQBUF, 0xC0585611),
    "VIDIOC_STREAMON": (VIDIOC_STREAMON, 0x40045612),
    "VIDIOC_STREAMOFF": (VIDIOC_STREAMOFF, 0x40045613),
    "VIDIOC_G_EXT_CTRLS": (VIDIOC_G_EXT_CTRLS, 0xC0205647),
    "VIDIOC_S_EXT_CTRLS": (VIDIOC_S_EXT_CTRLS, 0xC0205648),
}
_bad = {k: v for k, v in _EXPECTED.items() if v[0] != v[1]}
if _bad:
    for k, (got, want) in _bad.items():
        print(f"ioctl encoding wrong: {k} = 0x{got:08x}, expected 0x{want:08x}")
    raise SystemExit("struct layout does not match the kernel ABI")


# ------------------------------------------------------------------ plumbing
MEDIA = "/dev/media0"


def parse_graph(dev=MEDIA):
    """Structural parse of media-ctl -p.

    The link lines carry only the destination - '-> "X":0 [ENABLED]' - with the
    source implied by the enclosing pad, so this has to track the current
    entity and pad rather than regex whole lines.
    """
    out = subprocess.run(["media-ctl", "-p", "-d", dev],
                         capture_output=True, text=True).stdout
    ents, cur, pad = {}, None, None
    for line in out.splitlines():
        m = re.match(r"- entity \d+: (.+?) \(\d+ pad", line)
        if m:
            cur = {"name": m.group(1), "node": None, "pads": {}}
            ents[cur["name"]] = cur
            pad = None
            continue
        if cur is None:
            continue
        m = re.search(r"device node name (/dev/\S+)", line)
        if m:
            cur["node"] = m.group(1)
            continue
        m = re.match(r"\s*pad(\d+): (.+)", line)
        if m:
            pad = int(m.group(1))
            cur["pads"][pad] = {"dir": m.group(2).strip(), "out": [], "fmt": None}
            continue
        if pad is None:
            continue
        m = re.search(r"fmt:(\S+?)/(\d+)x(\d+)", line)
        if m and cur["pads"][pad]["fmt"] is None:
            cur["pads"][pad]["fmt"] = (m.group(1), int(m.group(2)), int(m.group(3)))
        m = re.search(r'->\s+"([^"]+)":(\d+)\s+\[([^\]]*)\]', line)
        if m:
            cur["pads"][pad]["out"].append(
                {"to": m.group(1), "topad": int(m.group(2)), "flags": m.group(3)})
    return ents


def locate(graph):
    """Return (sensor, csi2, csi2_pad, capture_entity, capture_node, fmt)."""
    sensor = next((n for n in graph if n.startswith("ov5675")), None)
    if not sensor:
        return None
    link = graph[sensor]["pads"][0]["out"]
    if not link:
        return None
    csi = link[0]["to"]
    cands = [(p, l) for p, d in sorted(graph[csi]["pads"].items())
             for l in d["out"] if "Capture" in l["to"]]
    if not cands:
        return None
    enabled = [(p, l) for p, l in cands if "ENABLED" in l["flags"]]
    cpad, clink = (enabled or cands)[0]
    cap = clink["to"]
    fmt = graph[sensor]["pads"][0]["fmt"] or ("SGRBG10_1X10", 1296, 972)
    return sensor, csi, cpad, cap, graph[cap]["node"], fmt


def mc(*args):
    r = subprocess.run(["media-ctl", "-d", MEDIA, *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"    media-ctl {' '.join(args)}: {r.stderr.strip()}")
    return r.returncode == 0


def setup_pipeline(sensor, csi, cpad, cap, fmt):
    """Enable the link and propagate formats.

    With v4l2-relayd stopped nothing has configured the graph, so the
    CSI2 -> Capture link is likely disabled and the pad formats stale. This is
    the work libcamera would normally do.
    """
    code, w, h = fmt
    print(f"  configuring {sensor}:0 -> {csi}:{cpad} -> {cap}  {code}/{w}x{h}")
    mc("-l", f'"{csi}":{cpad} -> "{cap}":0 [1]')
    for ent, p in ((sensor, 0), (csi, 0), (csi, cpad)):
        mc("-V", f'"{ent}":{p} [fmt:{code}/{w}x{h}]')


def ctrl_range(subdev, name):
    out = subprocess.run(["v4l2-ctl", "-d", subdev, "--list-ctrls"],
                         capture_output=True, text=True).stdout
    m = re.search(rf"{name}.*?min=(-?\d+) max=(-?\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


class Ctrls:
    """Direct ioctl access to the sensor's controls.

    Forking v4l2-ctl costs 5-10 ms, a meaningful slice of a 33 ms frame, and
    that jitter is what made the first exposure measurement split between 1 and
    2 frames. An ioctl on an already-open fd is microseconds.
    """

    def __init__(self, subdev):
        self.fd = os.open(subdev, os.O_RDWR)

    def _xfer(self, req, cid, value=0):
        c = ExtControl(id=cid, size=0)
        c.v.value = value
        cs = ExtControls(which=0, count=1, error_idx=0, request_fd=0,
                         controls=ctypes.pointer(c))
        fcntl.ioctl(self.fd, req, cs)
        return c.v.value

    def set(self, cid, value):
        self._xfer(VIDIOC_S_EXT_CTRLS, cid, value)

    def get(self, cid):
        return self._xfer(VIDIOC_G_EXT_CTRLS, cid)

    def close(self):
        os.close(self.fd)


# ------------------------------------------------------------------ capture
def fourcc(s):
    return sum(ord(c) << (8 * i) for i, c in enumerate(s))


class Capture:
    def __init__(self, node, want=None, pixfmt="BA10"):
        self.fd = os.open(node, os.O_RDWR)
        f = Format()
        f.type = BUF_TYPE_VIDEO_CAPTURE
        fcntl.ioctl(self.fd, VIDIOC_G_FMT, f)

        # media-ctl propagates subdev formats, but the video node's own format
        # is set separately and may be stale after the graph was reconfigured.
        #
        # pixfmt must correspond to the subdev's mbus code or IPU6 link
        # validation rejects the pipeline and VIDIOC_STREAMON fails EPIPE.
        # This used to be hardcoded BA10 (SGRBG10) and only worked by accident:
        # at the binned size the node's format already matched, so this branch
        # never ran. Requesting a different size took the branch and set a
        # pixel format that disagreed with an SGBRG10 subdev.
        if want and (f.fmt.pix.width, f.fmt.pix.height) != want:
            f.fmt.pix.width, f.fmt.pix.height = want
            f.fmt.pix.pixelformat = fourcc(pixfmt)
            f.fmt.pix.field = 1                      # NONE
            try:
                fcntl.ioctl(self.fd, VIDIOC_S_FMT, f)
            except OSError as e:
                print(f"    S_FMT {want[0]}x{want[1]} {pixfmt} failed: {e}")
            fcntl.ioctl(self.fd, VIDIOC_G_FMT, f)

        self.w, self.h = f.fmt.pix.width, f.fmt.pix.height
        self.stride, self.size = f.fmt.pix.bytesperline, f.fmt.pix.sizeimage
        cc = f.fmt.pix.pixelformat
        self.fourcc = "".join(chr((cc >> (8 * i)) & 0xFF) for i in range(4))

        r = RequestBuffers(count=NBUFS, type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS, r)
        self.n = r.count
        self.maps = []
        for i in range(self.n):
            b = Buffer(index=i, type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
            fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, b)
            self.maps.append(mmap.mmap(self.fd, b.length,
                                       mmap.MAP_SHARED, mmap.PROT_READ,
                                       offset=b.m.offset))
            fcntl.ioctl(self.fd, VIDIOC_QBUF, b)

    def start(self):
        fcntl.ioctl(self.fd, VIDIOC_STREAMON,
                    ctypes.c_uint32(BUF_TYPE_VIDEO_CAPTURE))

    def stop(self):
        try:
            fcntl.ioctl(self.fd, VIDIOC_STREAMOFF,
                        ctypes.c_uint32(BUF_TYPE_VIDEO_CAPTURE))
        except OSError:
            pass

    def frame(self):
        """Dequeue one frame, return (sequence, mean brightness, timestamp)."""
        b = Buffer(type=BUF_TYPE_VIDEO_CAPTURE, memory=MEMORY_MMAP)
        fcntl.ioctl(self.fd, VIDIOC_DQBUF, b)
        mv = self.maps[b.index]
        n = min(b.bytesused or self.size, len(mv))
        step = max(1, n // 4000)
        total = cnt = 0
        for off in range(0, n, step):
            total += mv[off]
            cnt += 1
        seq = b.sequence
        ts = b.timestamp.tv_sec + b.timestamp.tv_usec / 1e6
        fcntl.ioctl(self.fd, VIDIOC_QBUF, b)
        return seq, total / cnt, ts

    def close(self):
        for m in self.maps:
            m.close()
        os.close(self.fd)


# --------------------------------------------------------------------- trial
def trial(cap, ctrls, cid, low, high, settle=25, watch=12):
    """Set the control low, settle, step it high, find the frame that changes.

    Returns (delay, baseline, means, readback). The delay counts frames after
    the one that was in flight when the write happened: the write is issued
    immediately after dequeuing frame S, so means[0] is S+1 and a delay of n
    means the change first appeared in frame S+1+n.
    """
    ctrls.set(cid, low)
    base = []
    for _ in range(settle):
        base.append(cap.frame()[1])
    baseline = statistics.median(base[-10:])
    spread = statistics.pstdev(base[-10:]) or 0.5

    ctrls.set(cid, high)                  # microseconds after the DQBUF above
    readback = ctrls.get(cid)
    means, seqs = [], []
    for _ in range(watch):
        s, m, _ = cap.frame()
        seqs.append(s)
        means.append(m)

    # Frames must be consecutive or the frame accounting is meaningless.
    gaps = [b - a for a, b in zip(seqs, seqs[1:]) if b - a != 1]

    thresh = baseline + max(6 * spread, 0.08 * max(baseline, 1))
    delay = next((i for i, m in enumerate(means) if m > thresh), None)
    return delay, baseline, means, readback, gaps


def trial_timing(cap, ctrls, cid, low, high, settle=25, watch=12):
    """Same idea as trial(), but the observable is frame duration, not
    brightness. Stepping VBLANK lengthens the frame, which shows up as a jump
    in the interval between buffer timestamps."""
    ctrls.set(cid, low)
    ts = [cap.frame()[2] for _ in range(settle)]
    deltas = [b - a for a, b in zip(ts, ts[1:])]
    baseline = statistics.median(deltas[-10:])
    spread = statistics.pstdev(deltas[-10:]) or 1e-4

    ctrls.set(cid, high)
    readback = ctrls.get(cid)
    seqs, after = [], []
    prev = ts[-1]
    for _ in range(watch):
        s, _m, t = cap.frame()
        seqs.append(s)
        after.append(t - prev)
        prev = t

    gaps = [b - a for a, b in zip(seqs, seqs[1:]) if b - a != 1]
    thresh = baseline + max(6 * spread, 0.25 * baseline)
    delay = next((i for i, d in enumerate(after) if d > thresh), None)
    return delay, baseline, after, readback, gaps


def main():
    if os.geteuid() != 0:
        sys.exit("must run as root")

    graph = parse_graph()
    found = locate(graph)
    if not found:
        print("could not locate the sensor path in the media graph.")
        print("entities seen:")
        for n in graph:
            print("   ", n)
        sys.exit(1)
    sname, csi, cpad, cap, node, fmt = found
    subdev = graph[sname]["node"]
    print(f"sensor      {sname}  {subdev}")
    print(f"csi2        {csi}  pad{cpad}")
    print(f"capture     {cap}  {node}")
    if not node:
        sys.exit("capture entity has no device node")

    setup_pipeline(sname, csi, cpad, cap, fmt)

    emin, emax = ctrl_range(subdev, "exposure")
    gmin, gmax = ctrl_range(subdev, "analogue_gain")
    print(f"exposure    {emin}..{emax}")
    print(f"gain        {gmin}..{gmax}")

    cap = Capture(node, want=(fmt[1], fmt[2]))
    print(f"format      {cap.w}x{cap.h} {cap.fourcc} stride={cap.stride}\n")
    cap.start()

    ctrls = Ctrls(subdev)
    mid_exposure = max(emin, emax // 3)

    try:
        plan = (
            # (label, cid, low, high, bias)
            ("exposure", CID_EXPOSURE, max(emin, 8), mid_exposure, None),
            # Gain needs light to amplify. The first attempt measured gain with
            # exposure left at its minimum, so the frame was essentially black
            # and 16x of nothing is still nothing. Bias exposure to mid first.
            ("analogue_gain", CID_ANALOGUE_GAIN, gmin, gmax,
             (CID_EXPOSURE, mid_exposure)),
        )
        for label, cid, lo, hi, bias in plan:
            print(f"== {label} ==")
            if bias:
                ctrls.set(*bias)
                print(f"  bias: exposure={bias[1]} (so there is signal to amplify)")
                for _ in range(10):
                    cap.frame()
            results = []
            for run in range(1, 10):
                d, base, means, rb, gaps = trial(cap, ctrls, cid, lo, hi)
                shown = " ".join(f"{m:5.1f}" for m in means[:8])
                note = ""
                if rb != hi:
                    note += f"  [readback {rb} != {hi}]"
                if gaps:
                    note += f"  [dropped frames: {gaps}]"
                print(f"  run {run}: base {base:6.1f} | {shown}"
                      f" -> {'no change' if d is None else f'{d}'}{note}")
                if d is not None and not gaps:
                    results.append(d)
                ctrls.set(cid, lo)
                for _ in range(8):
                    cap.frame()
            if results:
                mode = statistics.mode(results)
                agree = results.count(mode)
                print(f"  --> raw offset = {mode}  ({agree}/{len(results)} agree,"
                      f" all: {results})")
                if agree < len(results) * 0.8:
                    print("      NOT conclusive - runs disagree, do not patch on this")
                else:
                    print(f"      => {label}Delay = {mode + 1}"
                          " (raw offset + 1; see the docstring for the convention)")
            else:
                print("  --> no measurable change")
            print()

        # VBLANK: observable as frame duration, not brightness.
        vmin, vmax = ctrl_range(subdev, "vertical_blanking")
        print("== vertical_blanking ==")
        if vmin is None or vmax <= vmin:
            print("  --> not writable on this sensor; skipping\n")
        else:
            hi = min(vmax, vmin * 4)
            print(f"  stepping {vmin} -> {hi} (frame gets longer)")
            results = []
            for run in range(1, 10):
                d, base, after, rb, gaps = trial_timing(cap, ctrls, CID_VBLANK,
                                                        vmin, hi)
                shown = " ".join(f"{x * 1000:5.1f}" for x in after[:8])
                note = f"  [readback {rb} != {hi}]" if rb != hi else ""
                if gaps:
                    note += f"  [dropped: {gaps}]"
                print(f"  run {run}: base {base * 1000:5.1f}ms | {shown}"
                      f" -> {'no change' if d is None else d}{note}")
                if d is not None and not gaps:
                    results.append(d)
                ctrls.set(CID_VBLANK, vmin)
                for _ in range(8):
                    cap.frame()
            if results:
                mode = statistics.mode(results)
                agree = results.count(mode)
                print(f"  --> raw offset = {mode}  ({agree}/{len(results)} agree,"
                      f" all: {results})")
                if agree < len(results) * 0.8:
                    print("      NOT conclusive - runs disagree")
                else:
                    print(f"      => vblankDelay = {mode + 1}")
            else:
                print("  --> no measurable change")
            print()
    finally:
        ctrls.close()
        cap.stop()
        cap.close()


if __name__ == "__main__":
    main()
