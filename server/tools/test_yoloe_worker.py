import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("yoloe_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class OverlapTests(unittest.TestCase):
    def test_overlap(self):
        self.assertAlmostEqual(worker.iou([0, 0, 0.5, 0.5], [0, 0, 0.5, 0.5]), 1)
        self.assertEqual(worker.iou([0, 0, 0.2, 0.2], [0.5, 0.5, 0.2, 0.2]), 0)

    def test_keeps_best_same_object_and_separates_distant_objects(self):
        tracks = []
        candidate = {"label": "chair", "t": 0, "box": [0, 0, 0.2, 0.2], "confidence": 0.4}
        worker.remember(tracks, candidate)
        worker.remember(tracks, {**candidate, "t": 1, "confidence": 0.8})
        self.assertEqual(len(tracks), 1)
        self.assertEqual(tracks[0]["best"]["t"], 1)
        worker.remember(tracks, {**candidate, "t": 1, "box": [0.7, 0.7, 0.2, 0.2]})
        self.assertEqual(len(tracks), 2)
        worker.remember(tracks, {**candidate, "t": 10})
        self.assertEqual(len(tracks), 3)  # No claim of persistent world identity after a gap.

    def test_chairs_do_not_crowd_out_other_detected_categories(self):
        candidates = [{"label": "chair", "confidence": 0.95 - i * 0.01} for i in range(10)]
        candidates += [{"label": "desk", "confidence": 0.6}, {"label": "door", "confidence": 0.4}]
        chosen = worker.diverse_best(candidates, 8, 2, lambda item: item["confidence"])
        self.assertEqual(sum(item["label"] == "chair" for item in chosen), 2)
        self.assertTrue({"desk", "door"}.issubset({item["label"] for item in chosen}))

    def test_new_categories_can_enter_after_many_chair_views(self):
        tracks = [{"label": "chair", "lastSeen": i, "lastBox": [0, 0, 0.2, 0.2],
                   "best": {"label": "chair", "confidence": 0.8}} for i in range(64)]
        worker.remember(tracks, {"label": "door", "t": 100, "box": [0.5, 0.5, 0.2, 0.2], "confidence": 0.4})
        self.assertTrue(any(track["label"] == "door" for track in tracks))


if __name__ == "__main__":
    unittest.main()
