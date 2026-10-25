"""Optional local detector. NDJSON on stdout, library logs on stderr; no HTTP service."""
import base64
import contextlib
import json
import math
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".cache" / "yoloe"
MODEL = "yoloe-26s-seg.pt"
NOTE = "sticky note"
CLASSES = [NOTE, "door", "window", "whiteboard", "light switch", "electrical outlet", "clock", "poster", "fire extinguisher", "air vent"]
PROMPTS = ["sticky note", "door", "window", "whiteboard", "light switch", "electrical outlet", "wall clock", "wall poster", "fire extinguisher", "wall air vent"]
FPS = 1
CONFIDENCE = 0.35
MAX_RESULTS = 8


def nearby_context(note_box, elements, width, height):
    """Same-frame image evidence only; no physical distance/wall attachment claim."""
    x, y, w, h = note_box
    def gap(item):
        a, b, c, d = item["box"]
        dx = max(a - (x + w), x - (a + c), 0) * width
        dy = max(b - (y + h), y - (b + d), 0) * height
        return math.hypot(dx, dy) / math.hypot(width, height)
    return [{**item, "imageGap": round(gap(item), 6)} for item in
            sorted(elements, key=gap) if gap(item) <= 0.2][:6]


def final_notes(tracks):
    return sorted([track["best"] for track in tracks if track["label"] == NOTE],
                  key=lambda item: item["confidence"], reverse=True)[:MAX_RESULTS]


def diverse_best(items, limit, per_class, score):
    buckets = {}
    for item in sorted(items, key=score, reverse=True):
        buckets.setdefault(item["label"], []).append(item)
    ordered = sorted(buckets.values(), key=lambda bucket: score(bucket[0]), reverse=True)
    selected = []
    for rank in range(per_class):
        for bucket in ordered:
            if rank < len(bucket):
                selected.append(bucket[rank])
                if len(selected) == limit:
                    return selected
    return selected


def emit(event):
    print(json.dumps(event, allow_nan=False), flush=True)


def iou(a, b):
    x = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    y = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    intersection = x * y
    return intersection / max(a[2] * a[3] + b[2] * b[3] - intersection, 1e-9)


def remember(tracks, candidate):
    matches = [track for track in tracks if track["label"] == candidate["label"]
               and candidate["t"] - track["lastSeen"] <= 2.1
               and iou(track["lastBox"], candidate["box"]) >= 0.3]
    if matches:
        track = max(matches, key=lambda item: iou(item["lastBox"], candidate["box"]))
        track["lastSeen"] = candidate["t"]
        track["lastBox"] = candidate["box"]
        if candidate["confidence"] > track["best"]["confidence"]:
            track["best"] = candidate
    else:
        track = {"label": candidate["label"], "lastSeen": candidate["t"],
                 "lastBox": candidate["box"], "best": candidate}
        tracks[:] = diverse_best(tracks + [track], 64, 64, lambda item: item["best"]["confidence"])


def load_model():
    CACHE.mkdir(parents=True, exist_ok=True)
    os.chdir(CACHE)
    os.environ.setdefault("YOLO_CONFIG_DIR", str(CACHE / "settings"))
    os.environ.setdefault("YOLO_AUTOINSTALL", "false")
    os.environ.setdefault("MPLBACKEND", "Agg")
    # PyTorch/Ultralytics may write ordinary status messages; keep stdout machine-readable.
    with contextlib.redirect_stdout(sys.stderr):
        import torch
        from ultralytics import YOLOE
        torch.set_num_threads(min(4, os.cpu_count() or 1))
        model = YOLOE(MODEL)
        model.set_classes(PROMPTS)
    return model


def analyze_video(model, spec):
    import cv2
    capture = cv2.VideoCapture(spec["path"])
    if not capture.isOpened():
        raise ValueError("Cannot decode this MP4/MOV. Try an H.264 export.")
    if hasattr(cv2, "CAP_PROP_ORIENTATION_AUTO"):
        capture.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    source_fps = capture.get(cv2.CAP_PROP_FPS)
    if not math.isfinite(source_fps) or source_fps <= 0:
        capture.release()
        raise ValueError("Video frame rate is unavailable; export a complete video.")
    tracks = []
    next_sample = 0.0
    frame_index = -1
    analyzed = 0
    last_t = -1.0
    fallback_timestamps = False
    diagnostics = {name: {} for name in ["proposalsByClass", "belowThresholdByClass", "areaRejectedByClass", "acceptedByClass", "selectedByClass"]}
    def count(group, label):
        diagnostics[group][label] = diagnostics[group].get(label, 0) + 1
    try:
        while capture.grab():
            frame_index += 1
            t = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
            if not math.isfinite(t) or (frame_index > 0 and t <= last_t):
                t = frame_index / source_fps
                fallback_timestamps = True
            last_t = t
            if t >= spec["duration"] or t >= 120:
                break
            if t + 1e-6 < next_sample:
                continue
            ok, frame = capture.retrieve()
            if not ok:
                raise ValueError("A sampled video frame could not be decoded.")
            next_sample = t + 1.0 / FPS
            with contextlib.redirect_stdout(sys.stderr):
                results = model.predict(frame, device="cpu", imgsz=960, conf=0.20,
                                        iou=0.5, max_det=64, verbose=False)
            analyzed += 1
            result = results[0]
            if result.boxes is not None and len(result.boxes):
                height, width = frame.shape[:2]
                ratio = min(1.0, 960.0 / max(width, height))
                thumbnail = cv2.resize(frame, (round(width * ratio), round(height * ratio))) if ratio < 1 else frame
                success, encoded = cv2.imencode(".jpg", thumbnail, [cv2.IMWRITE_JPEG_QUALITY, 72])
                if not success:
                    raise ValueError("Cannot encode a detection preview.")
                notes, elements = [], []
                for box, score, class_id in zip(result.boxes.xyxyn.cpu().tolist(),
                                                 result.boxes.conf.cpu().tolist(), result.boxes.cls.cpu().tolist()):
                    x1, y1, x2, y2 = [max(0.0, min(1.0, float(value))) for value in box]
                    normalized = [x1, y1, x2 - x1, y2 - y1]
                    area = normalized[2] * normalized[3]
                    label = CLASSES[int(class_id)]
                    count("proposalsByClass", label)
                    if score < CONFIDENCE:
                        count("belowThresholdByClass", label)
                        continue
                    # Small wall notes must survive the old furniture-size filter.
                    min_area = 0.0001 if label == NOTE else 0.001
                    if area < min_area or area > (0.5 if label == NOTE else 0.9):
                        count("areaRejectedByClass", label)
                        continue
                    count("acceptedByClass", label)
                    detection = {"label": label, "box": normalized, "confidence": float(score)}
                    if label == NOTE:
                        notes.append(detection)
                    else:
                        elements.append(detection)
                for note in notes:
                    remember(tracks, {**note, "t": t, "frameIndex": frame_index, "jpeg": encoded.tobytes(),
                                      "context": nearby_context(note["box"], elements, width, height)})
            if analyzed == 1 or analyzed % 10 == 0:
                emit({"type": "progress", "message": f"YOLOE {spec['pass']}: {analyzed} frames analyzed, at {t:.1f}s"})
    finally:
        capture.release()
    if analyzed == 0:
        raise ValueError("No video frames could be analyzed.")
    best = final_notes(tracks)
    detections = []
    import numpy as np
    for candidate in sorted(best, key=lambda item: item["t"]):
        count("selectedByClass", candidate["label"])
        image = cv2.imdecode(np.frombuffer(candidate["jpeg"], dtype=np.uint8), cv2.IMREAD_COLOR)
        h, w = image.shape[:2]
        x, y, bw, bh = candidate["box"]
        cv2.rectangle(image, (round(x * w), round(y * h)), (round((x + bw) * w), round((y + bh) * h)), (100, 230, 150), 2)
        for element in candidate["context"]:
            a, b, c, d = element["box"]
            cv2.rectangle(image, (round(a * w), round(b * h)), (round((a + c) * w), round((b + d) * h)), (240, 180, 90), 1)
            cv2.putText(image, element["label"], (round(a * w), max(12, round(b * h))), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (240, 180, 90), 1)
        caption = f"{candidate['label']} | score {candidate['confidence']:.2f} | {candidate['t']:.2f}s"
        cv2.putText(image, caption, (8, max(20, round(y * h) - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (100, 230, 150), 1, cv2.LINE_AA)
        ok, jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 72])
        detection = {key: value for key, value in candidate.items() if key != "jpeg"}
        if ok and jpeg.nbytes <= 256 * 1024:
            detection["frameJpeg"] = base64.b64encode(jpeg).decode("ascii")
        detections.append(detection)
    return {"pass": spec["pass"], "duration": spec["duration"], "detections": detections,
            "framesAnalyzed": analyzed, "diagnostics": diagnostics,
            "timestampSource": "frame-index/fps fallback" if fallback_timestamps else "decoder presentation time"}


def main():
    emit({"type": "progress", "message": "Loading YOLOE-26 Small: sticky-note candidates and wall context on CPU..."})
    model = load_model()
    if "--warmup" in sys.argv:
        import numpy as np
        with contextlib.redirect_stdout(sys.stderr):
            model.predict(np.zeros((640, 640, 3), dtype=np.uint8), device="cpu", imgsz=640, verbose=False)
        (CACHE / "ready.json").write_text(json.dumps({"model": MODEL, "classes": CLASSES, "prompts": PROMPTS}), encoding="utf-8")
        emit({"type": "ready", "model": MODEL, "classes": CLASSES})
        return
    job = json.load(sys.stdin)
    if not isinstance(job.get("videos"), list) or len(job["videos"]) != 2:
        raise ValueError("Expected overview and edge videos.")
    started = time.monotonic()
    passes = [analyze_video(model, spec) for spec in job["videos"]]
    emit({"type": "result", "model": MODEL, "elapsedMs": round((time.monotonic() - started) * 1000),
          "passes": passes, "analysis": {"engine": "yoloe", "device": "cpu", "fps": FPS,
          "confidenceThreshold": CONFIDENCE, "classes": CLASSES, "maxObjectsPerPass": MAX_RESULTS,
          "prompts": PROMPTS, "imageSize": 960, "candidateLabel": NOTE, "maxCandidatesPerClass": MAX_RESULTS,
          "contextMetric": "same-frame box gap / image diagonal; not meters",
          "deduplication": "short image-space overlap tracks; not persistent world identities"},
          "usage": None, "cleanupWarnings": []})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"YOLOE worker: {error}", file=sys.stderr)
        emit({"type": "error", "code": "YOLOE_FAILED", "message": "Local YOLOE failed. Check the backend worker log and video encoding."})
        sys.exit(1)
