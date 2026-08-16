import io
import sys
import types
import unittest
from unittest import mock

import numpy as np

try:
    import flask_cors  # noqa: F401
except ModuleNotFoundError:
    flask_cors_stub = types.ModuleType("flask_cors")
    flask_cors_stub.CORS = lambda app: app
    sys.modules["flask_cors"] = flask_cors_stub

from backend import app as scanner


class FakeInputs(dict):
    def to(self, _device):
        return self


class FakeModel:
    def __call__(self, **_inputs):
        return object()


class FakeProcessor:
    def __call__(self, **_kwargs):
        return FakeInputs()

    def post_process_instance_segmentation(self, *_args, **_kwargs):
        return [{"masks": []}]


class ExtractionFailureIsolationTests(unittest.TestCase):
    def setUp(self):
        self.task_id = "failure-isolation-test"
        self.candidates = [
            {
                "area": 100.0,
                "vertices": np.array(
                    [[0, 0], [4, 0], [4, 4], [0, 4]],
                    dtype=np.float64,
                ),
            },
            {
                "area": 100.0,
                "vertices": np.array(
                    [[10, 0], [14, 0], [14, 4], [10, 4]],
                    dtype=np.float64,
                ),
            },
        ]
        with scanner.task_lock:
            scanner.task_store[self.task_id] = {
                "status": "processing",
                "phase": "waiting",
                "results": [],
                "white_balance": False,
                "denoise": False,
                "postprocess_mode": scanner.POSTPROCESS_MODE_OFF,
                "requested_polaroids": 0,
                "rotation_degrees": 0,
                "polaroid_size": scanner.POLAROID_SIZE_AUTO,
                "cancel_requested": False,
            }

        image = scanner.Image.new("RGB", (2, 2), color=(255, 255, 255))
        encoded = io.BytesIO()
        image.save(encoded, format="PNG")
        self.raw_image = encoded.getvalue()

    def tearDown(self):
        with scanner.task_lock:
            scanner.task_store.pop(self.task_id, None)

    def run_extraction(self, candidate_extractor):
        with (
            mock.patch.object(
                scanner,
                "get_sam3",
                return_value=(FakeModel(), FakeProcessor(), "cpu"),
            ),
            mock.patch.object(
                scanner,
                "build_detection_candidates",
                return_value=self.candidates,
            ),
            mock.patch.object(
                scanner,
                "extract_polaroid_candidate",
                side_effect=candidate_extractor,
            ),
        ):
            scanner.do_process_extraction(self.raw_image, self.task_id)

        with scanner.task_lock:
            return scanner.task_store[self.task_id]

    def test_one_candidate_failure_keeps_later_success_and_finishes_done(self):
        def extract_candidate(*args):
            candidate_number = args[-1]
            if candidate_number == 1:
                raise RuntimeError("private candidate failure detail")
            return b"complete-second-result"

        task = self.run_extraction(extract_candidate)

        self.assertEqual(task["status"], "done")
        self.assertEqual(task["phase"], "complete")
        self.assertEqual(task["error"], "")
        self.assertTrue(task["extraction_complete"])
        self.assertEqual(task["total_polaroids"], 2)
        self.assertEqual(len(task["results"]), 1)
        self.assertEqual(task["results"][0]["id"], 0)
        self.assertEqual(task["results"][0]["label"], "拍立得 #2")
        self.assertEqual(task["results"][0]["image_bytes"], b"complete-second-result")
        self.assertIn("1/2", task["warning"])
        self.assertNotIn("private candidate failure detail", task["warning"])

    def test_all_candidate_failures_finish_failed_without_partial_result(self):
        def extract_candidate(*_args):
            raise RuntimeError("private candidate failure detail")

        task = self.run_extraction(extract_candidate)

        self.assertEqual(task["status"], "failed")
        self.assertEqual(task["phase"], "complete")
        self.assertEqual(task["error"], "所有拍立得候选提取失败")
        self.assertTrue(task["extraction_complete"])
        self.assertEqual(task["results"], [])
        self.assertIn("2/2", task["warning"])
        self.assertNotIn("private candidate failure detail", task["warning"])
        self.assertNotIn("private candidate failure detail", task["error"])


class DirectChekiProcessingTests(unittest.TestCase):
    def setUp(self):
        self.task_ids = []

    def tearDown(self):
        with scanner.task_lock:
            for task_id in self.task_ids:
                scanner.task_store.pop(task_id, None)
        with scanner.queue_lock:
            scanner.task_queue[:] = [
                task_id for task_id in scanner.task_queue
                if task_id not in self.task_ids
            ]

    def image_bytes(self, size=(8, 12), *, exif_orientation=None):
        image = scanner.Image.new("RGB", size, color=(220, 220, 220))
        encoded = io.BytesIO()
        if exif_orientation is None:
            image.save(encoded, format="PNG")
        else:
            exif = scanner.Image.Exif()
            exif[274] = exif_orientation
            image.save(encoded, format="JPEG", exif=exif)
        return encoded.getvalue()

    def make_task(
        self,
        *,
        polaroid_size=scanner.POLAROID_SIZE_AUTO,
        rotation_degrees=0,
        white_balance=False,
        postprocess_mode=scanner.POSTPROCESS_MODE_OFF,
    ):
        task_id = f"direct-{len(self.task_ids)}"
        self.task_ids.append(task_id)
        with scanner.task_lock:
            scanner.task_store[task_id] = {
                "status": "processing",
                "phase": "waiting",
                "results": [],
                "direct": True,
                "white_balance": white_balance,
                "denoise": postprocess_mode != scanner.POSTPROCESS_MODE_OFF,
                "postprocess_mode": postprocess_mode,
                "requested_polaroids": 1,
                "rotation_degrees": rotation_degrees,
                "polaroid_size": polaroid_size,
                "cancel_requested": False,
            }
        return task_id

    def result_size(self, task):
        image = scanner.Image.open(io.BytesIO(task["results"][0]["image_bytes"]))
        return image.size

    def test_direct_skips_sam3_and_publishes_exactly_one_normal_result(self):
        cases = [
            (scanner.POLAROID_SIZE_MINI, (20, 10), (1200, 1908)),
            (scanner.POLAROID_SIZE_WIDE, (10, 20), (2400, 1908)),
            (scanner.POLAROID_SIZE_AUTO, (20, 10), (2400, 1908)),
            (scanner.POLAROID_SIZE_AUTO, (10, 20), (1200, 1908)),
        ]
        with (
            mock.patch.object(scanner, "get_sam3", side_effect=AssertionError("SAM3 must not load")),
            mock.patch.object(scanner.torch, "no_grad", side_effect=AssertionError("inference must not run")),
        ):
            for polaroid_size, source_size, expected_size in cases:
                with self.subTest(polaroid_size=polaroid_size, source_size=source_size):
                    task_id = self.make_task(polaroid_size=polaroid_size)
                    scanner.do_process_extraction(self.image_bytes(source_size), task_id)
                    with scanner.task_lock:
                        task = scanner.task_store[task_id]
                    self.assertEqual(task["status"], "done")
                    self.assertEqual(task["phase"], "complete")
                    self.assertTrue(task["extraction_complete"])
                    self.assertEqual(task["expected_polaroids"], 1)
                    self.assertEqual(task["total_polaroids"], 1)
                    self.assertEqual(task["detected_polaroids"], 1)
                    self.assertEqual(len(task["results"]), 1)
                    self.assertEqual(task["results"][0]["type"], "polaroid")
                    self.assertEqual(task["results"][0]["label"], "拍立得 #1")
                    self.assertEqual(self.result_size(task), expected_size)

    def test_direct_resize_uses_area_for_shrink_and_cubic_for_enlarge(self):
        geometry = scanner.get_polaroid_geometry(scanner.POLAROID_SIZE_MINI)
        with mock.patch.object(
            scanner.cv2,
            "resize",
            return_value=np.zeros((2, 2, 3), dtype=np.uint8),
        ) as resize:
            scanner.resize_direct_cheki(
                np.zeros((2000, 1300, 3), dtype=np.uint8),
                geometry,
            )
            self.assertEqual(resize.call_args.kwargs["interpolation"], scanner.cv2.INTER_AREA)
            scanner.resize_direct_cheki(
                np.zeros((20, 10, 3), dtype=np.uint8),
                geometry,
            )
            self.assertEqual(resize.call_args.kwargs["interpolation"], scanner.cv2.INTER_CUBIC)

    def test_direct_applies_exif_rotation_white_balance_and_postprocess(self):
        task_id = self.make_task(
            rotation_degrees=90,
            white_balance=True,
            postprocess_mode=scanner.POSTPROCESS_MODE_SHARPEN,
        )
        captured = {}

        def fake_resize(image, geometry):
            captured["oriented_shape"] = image.shape[:2]
            captured["geometry"] = geometry
            with scanner.task_lock:
                captured["phase"] = scanner.task_store[task_id]["phase"]
            return np.zeros((4, 3, 3), dtype=np.uint8)

        with (
            mock.patch.object(scanner, "get_sam3", side_effect=AssertionError("SAM3 must not load")),
            mock.patch.object(scanner, "resize_direct_cheki", side_effect=fake_resize),
            mock.patch.object(
                scanner,
                "apply_fixed_border_white_balance",
                side_effect=lambda image, _geometry: (image, {"applied": True}),
            ) as white_balance,
            mock.patch.object(
                scanner,
                "apply_postprocess_mode",
                side_effect=lambda image, _mode: (image, {"applied": True}),
            ) as postprocess,
        ):
            scanner.do_process_extraction(
                self.image_bytes((2, 3), exif_orientation=6),
                task_id,
            )

        # EXIF orientation 6 changes 2x3 to 3x2, then the requested 90°
        # rotation changes it back to portrait 2x3 before auto-size selection.
        self.assertEqual(captured["oriented_shape"], (3, 2))
        self.assertEqual(captured["geometry"]["width"], 1200)
        self.assertEqual(captured["phase"], "direct_processing")
        white_balance.assert_called_once()
        self.assertEqual(
            postprocess.call_args.args[1],
            scanner.POSTPROCESS_MODE_SHARPEN,
        )

    def test_direct_cancellation_keeps_stable_single_result_counts(self):
        task_id = self.make_task(polaroid_size=scanner.POLAROID_SIZE_MINI)

        def cancel_during_resize(_image, _geometry):
            scanner.mark_task_canceled(task_id)
            return np.zeros((4, 3, 3), dtype=np.uint8)

        with (
            mock.patch.object(scanner, "get_sam3", side_effect=AssertionError("SAM3 must not load")),
            mock.patch.object(scanner, "resize_direct_cheki", side_effect=cancel_during_resize),
        ):
            scanner.do_process_extraction(self.image_bytes(), task_id)

        with scanner.task_lock:
            task = scanner.task_store[task_id]
        self.assertEqual(task["status"], scanner.CANCELED_STATUS)
        self.assertEqual(task["phase"], scanner.CANCELED_STATUS)
        self.assertTrue(task["extraction_complete"])
        self.assertEqual(task["expected_polaroids"], 1)
        self.assertEqual(task["total_polaroids"], 1)
        self.assertEqual(task["detected_polaroids"], 1)
        self.assertEqual(task["results"], [])

    def test_direct_failure_is_fixed_and_does_not_expose_input_details(self):
        task_id = self.make_task()
        private_detail = "private-input-detail"
        with (
            mock.patch.object(scanner, "get_sam3", side_effect=AssertionError("SAM3 must not load")),
            mock.patch.object(
                scanner,
                "resize_direct_cheki",
                side_effect=RuntimeError(private_detail),
            ),
        ):
            scanner.do_process_extraction(self.image_bytes(), task_id)

        with scanner.task_lock:
            task = scanner.task_store[task_id]
        self.assertEqual(task["status"], "failed")
        self.assertEqual(task["phase"], "complete")
        self.assertEqual(task["error"], "Direct Cheki processing failed")
        self.assertNotIn(private_detail, task["error"])
        self.assertTrue(task["extraction_complete"])
        self.assertEqual(task["expected_polaroids"], 1)
        self.assertEqual(task["total_polaroids"], 1)
        self.assertEqual(task["detected_polaroids"], 1)
        self.assertEqual(task["results"], [])

    def test_process_form_direct_is_optional_and_overrides_count_to_one(self):
        raw_image = self.image_bytes()
        requests = [
            ({"direct": "yes", "expected_polaroids": "7"}, True, 1, 1, 1),
            ({"expected_polaroids": "7"}, False, 7, 0, 0),
        ]
        with mock.patch.object(scanner, "start_sam3_prewarm") as prewarm:
            for fields, expected_direct, expected_count, total, detected in requests:
                with self.subTest(fields=fields):
                    calls_before = prewarm.call_count
                    data = {
                        "image": (io.BytesIO(raw_image), "cheki.png"),
                        **fields,
                    }
                    with scanner.app.test_request_context(
                        "/api/process",
                        method="POST",
                        data=data,
                    ):
                        response = scanner.submit_task()
                    payload = response.get_json()
                    task_id = payload["task_id"]
                    self.task_ids.append(task_id)
                    with scanner.task_lock:
                        task = scanner.task_store[task_id]
                    self.assertEqual(task["direct"], expected_direct)
                    self.assertEqual(task["requested_polaroids"], expected_count)
                    self.assertEqual(task["expected_polaroids"], expected_count)
                    self.assertEqual(task["total_polaroids"], total)
                    self.assertEqual(task["detected_polaroids"], detected)
                    self.assertEqual(payload["expected_polaroids"], expected_count)
                    self.assertEqual(
                        prewarm.call_count,
                        calls_before if expected_direct else calls_before + 1,
                    )

    def test_standard_scan_prewarm_is_single_flight_and_retries_after_failure(self):
        class ImmediateThread:
            def __init__(self, *, target, **_kwargs):
                self.target = target

            def start(self):
                self.target()

        with scanner.MODEL_PREWARM_LOCK:
            scanner._sam3_prewarm_started = False
        with (
            mock.patch.object(scanner.threading, "Thread", ImmediateThread),
            mock.patch.object(scanner, "get_sam3", return_value=(object(), object(), "cpu")) as get_sam3,
        ):
            self.assertTrue(scanner.start_sam3_prewarm())
            self.assertFalse(scanner.start_sam3_prewarm())
        get_sam3.assert_called_once()

        with scanner.MODEL_PREWARM_LOCK:
            scanner._sam3_prewarm_started = False
        with (
            mock.patch.object(scanner.threading, "Thread", ImmediateThread),
            mock.patch.object(scanner, "get_sam3", side_effect=RuntimeError("private failure")),
        ):
            self.assertTrue(scanner.start_sam3_prewarm())
        with scanner.MODEL_PREWARM_LOCK:
            self.assertFalse(scanner._sam3_prewarm_started)


if __name__ == "__main__":
    unittest.main()
