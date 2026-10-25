import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("yoloe_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class OverlapTests(unittest.TestCase):
    def test_scene_alignment_links_moving_notes_without_merging_distinct_notes(self):
        import cv2
        import numpy as np
        rng = np.random.default_rng(23)
        before = rng.integers(0, 256, (320, 480), dtype=np.uint8)
        after = cv2.warpAffine(before, np.float32([[1, 0, 55], [0, 1, 12]]), (480, 320))
        tracks = []
        for x in [0.3, 0.5]:
            worker.remember(tracks, {"label": worker.NOTE, "box": [x, 0.4, 0.04, 0.04], "t": 0, "confidence": 0.6})
        self.assertTrue(worker.align_tracks(tracks, before, after, 1))
        for x in [0.3, 0.5]:
            worker.remember(tracks, {"label": worker.NOTE, "box": [x+55/480, 0.4+12/320, 0.04, 0.04], "t": 1, "confidence": 0.9})
        notes = worker.final_notes(tracks)
        self.assertEqual(len(notes), 2)
        self.assertEqual([item["observationCount"] for item in notes], [2, 2])
        self.assertEqual([item["t"] for item in notes], [1, 1])

    def test_textureless_frames_do_not_invent_camera_alignment(self):
        import numpy as np
        image = np.zeros((240, 320), dtype=np.uint8)
        self.assertFalse(worker.align_tracks([], None, image, 1))
        self.assertFalse(worker.align_tracks([], image, image, 1))

    def test_same_frame_triplicate_keeps_highest_score_before_context(self):
        notes = [
            {"label": worker.NOTE, "box": [0.2, 0.2, 0.1, 0.1], "confidence": 0.6},
            {"label": worker.NOTE, "box": [0.201, 0.202, 0.095, 0.096], "confidence": 0.9},
            {"label": worker.NOTE, "box": [0.205, 0.205, 0.08, 0.08], "confidence": 0.7},
        ]
        selected = worker.suppress_overlapping_notes(notes)
        self.assertEqual(selected, [notes[1]])

    def test_nested_duplicate_suppressed_but_distinct_nearby_notes_survive(self):
        notes = [
            {"label": worker.NOTE, "box": [0.1, 0.1, 0.1, 0.1], "confidence": 0.9},
            {"label": worker.NOTE, "box": [0.12, 0.12, 0.03, 0.03], "confidence": 0.8},
            {"label": worker.NOTE, "box": [0.21, 0.1, 0.1, 0.1], "confidence": 0.7},
        ]
        self.assertEqual(worker.suppress_overlapping_notes(notes), [notes[0], notes[2]])

    def test_two_notes_in_one_frame_cannot_update_the_same_track(self):
        tracks = []
        note = {"label": worker.NOTE, "box": [0.1, 0.1, 0.1, 0.1], "t": 0, "confidence": 0.8}
        worker.remember(tracks, note)
        worker.remember(tracks, {**note, "t": 1})
        worker.remember(tracks, {**note, "t": 1, "box": [0.12, 0.1, 0.1, 0.1]})
        self.assertEqual(len(tracks), 2)

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
