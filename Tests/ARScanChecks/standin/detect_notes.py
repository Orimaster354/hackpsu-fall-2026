#!/usr/bin/env python3
"""TEST STAND-IN for the server's YOLOE step: finds bright yellow blobs (sticky notes) with plain colour
thresholds. No ML, no numpy. It only exists so a real capture can be checked end to end before the
real detector is wired in. Usage: detect_notes.py image.jpg [image2.jpg ...]  -> JSON {path: [boxes]}"""
import json
import sys

from PIL import Image, ImageChops

MIN_AREA = 14        # pixels at half resolution (so about 56 px in the full image)
MIN_FILL = 0.55      # blob area / bounding box area: notes are solid squares
MAX_ASPECT = 2.2


def detect(path):
    full = Image.open(path).convert("RGB")
    small = full.reduce(2)
    hue, sat, val = small.convert("HSV").split()
    mask = ImageChops.multiply(
        ImageChops.multiply(hue.point(lambda v: 255 if 21 <= v <= 53 else 0), sat.point(lambda v: 255 if v >= 120 else 0)),
        val.point(lambda v: 255 if v >= 150 else 0),
    )
    width, height = mask.size
    data = mask.tobytes()
    seen = bytearray(len(data))
    boxes = []
    for start in range(len(data)):
        if not data[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        min_x = max_x = start % width
        min_y = max_y = start // width
        count = 0
        while stack:
            i = stack.pop()
            x, y = i % width, i // width
            count += 1
            min_x, max_x, min_y, max_y = min(min_x, x), max(max_x, x), min(min_y, y), max(max_y, y)
            for j in (i - 1 if x > 0 else -1, i + 1 if x < width - 1 else -1, i - width if y > 0 else -1, i + width if y < height - 1 else -1):
                if j >= 0 and data[j] and not seen[j]:
                    seen[j] = 1
                    stack.append(j)
        w, h = max_x - min_x + 1, max_y - min_y + 1
        if count < MIN_AREA or count / (w * h) < MIN_FILL or max(w, h) / min(w, h) > MAX_ASPECT:
            continue
        boxes.append({"box": [min_x * 2, min_y * 2, w * 2, h * 2], "area": count * 4})
    return sorted(boxes, key=lambda b: -b["area"])


if __name__ == "__main__":
    print(json.dumps({p: detect(p) for p in sys.argv[1:]}))
