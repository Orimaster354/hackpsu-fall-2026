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

    def test_multiple_notes_survive_without_becoming_context_task_locations(self):
        tracks = [{"label": worker.NOTE, "best": {"label": worker.NOTE, "confidence": 0.9 - i * 0.01}}
                  for i in range(10)]
        tracks.append({"label": "door", "best": {"label": "door", "confidence": 0.99}})
        selected = worker.final_notes(tracks)
        self.assertEqual(len(selected), 8)
        self.assertTrue(all(item["label"] == worker.NOTE for item in selected))

    def test_context_is_bounded_image_gap_not_distance_between_frames(self):
        note = [0.1, 0.1, 0.05, 0.05]
        elements = [
            {"label": "whiteboard", "box": [0.2, 0.1, 0.2, 0.2], "confidence": 0.8},
            {"label": "window", "box": [0.8, 0.8, 0.1, 0.1], "confidence": 0.9},
            {"label": "poster", "box": [0.1, 0.1, 0.1, 0.1], "confidence": 0.7},
        ]
        context = worker.nearby_context(note, elements, 1000, 500)
        self.assertEqual([item["label"] for item in context], ["poster", "whiteboard"])
        self.assertEqual(context[0]["imageGap"], 0)
        self.assertAlmostEqual(context[1]["imageGap"], 50 / (1000**2 + 500**2)**0.5, places=6)
        self.assertEqual(worker.nearby_context(note, [], 1000, 500), [])

    def test_best_note_keeps_context_from_its_own_frame(self):
        tracks = []
        note = {"label": worker.NOTE, "t": 0, "box": [0.1, 0.1, 0.02, 0.02],
                "confidence": 0.9, "context": [{"label": "whiteboard"}]}
        worker.remember(tracks, note)
        worker.remember(tracks, {**note, "t": 1, "confidence": 0.6, "context": [{"label": "door"}]})
        selected = worker.final_notes(tracks)[0]
        self.assertEqual(selected["t"], 0)
        self.assertEqual(selected["context"][0]["label"], "whiteboard")


if __name__ == "__main__":
    unittest.main()
