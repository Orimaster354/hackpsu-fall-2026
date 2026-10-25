#!/usr/bin/env python3
"""Renders the reference sweep fixture (docs/fixtures/postit/sweep-observations.json) as JPEGs: a grey wall with a
yellow rectangle wherever a sticky note was detected. Used only by the stand-in's self test."""
import json
import sys

from PIL import Image, ImageDraw

fixture = json.load(open(sys.argv[1]))
out = sys.argv[2]
width, height = fixture["intrinsics"]["width"], fixture["intrinsics"]["height"]
for frame in fixture["frames"]:
    image = Image.new("RGB", (width, height), (70, 72, 80))
    draw = ImageDraw.Draw(image)
    for detection in frame["detections"]:
        for context in detection.get("context", []):
            x, y, w, h = context["box"]
            draw.rectangle([x, y, x + w - 1, y + h - 1], fill=(110, 80, 60))
        x, y, w, h = detection["box"]
        draw.rectangle([x, y, x + w - 1, y + h - 1], fill=(250, 225, 40))
    image.save(f"{out}/frame-{frame['index']:03d}.jpg", quality=88)
