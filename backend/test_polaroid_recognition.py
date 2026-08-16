from __future__ import annotations

import io
import json
import os
import unittest
from contextlib import redirect_stdout
from unittest import mock

import numpy as np
from PIL import Image

from backend import app as backend_app
from backend import date_annotation_callback
from backend import polaroid_recognition


def png_bytes(size=(8, 8), color=(20, 40, 60)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", size, color).save(buffer, format="PNG")
    return buffer.getvalue()


class ProcessInkContractTests(unittest.TestCase):
    def setUp(self):
        self.previous_proxy_mode = backend_app.TRUST_LOOPBACK_PROXY
        backend_app.TRUST_LOOPBACK_PROXY = True
        backend_app.app.config.update(TESTING=True)
        self.client = backend_app.app.test_client()
        with backend_app.task_lock:
            backend_app.task_store.clear()
        with backend_app.queue_lock:
            backend_app.task_queue.clear()
        with backend_app.rate_lock:
            backend_app.rate_store.clear()

    def tearDown(self):
        backend_app.TRUST_LOOPBACK_PROXY = self.previous_proxy_mode
        with backend_app.task_lock:
            backend_app.task_store.clear()
        with backend_app.queue_lock:
            backend_app.task_queue.clear()

    def post_image(self, ink=None):
        data = {
            "image": (io.BytesIO(png_bytes()), "source.png"),
        }
        if ink is not None:
            data["ink"] = ink
        with redirect_stdout(io.StringIO()):
            return self.client.post(
                "/api/process",
                data=data,
                content_type="multipart/form-data",
            )

    def test_missing_ink_defaults_to_zero_and_queues_once(self):
        response = self.post_image()
        self.assertEqual(response.status_code, 200)
        payload = response.get_json()
        self.assertEqual(payload["ink"], 0)
        with backend_app.queue_lock:
            self.assertEqual(len(backend_app.task_queue), 1)
        with backend_app.task_lock:
            self.assertFalse(
                backend_app.task_store[payload["task_id"]]["ink"]
            )

    def test_accepts_explicit_zero_and_one(self):
        for value, expected in (("0", False), ("1", True)):
            with self.subTest(value=value):
                with backend_app.task_lock:
                    backend_app.task_store.clear()
                with backend_app.queue_lock:
                    backend_app.task_queue.clear()
                response = self.post_image(value)
                self.assertEqual(response.status_code, 200)
                payload = response.get_json()
                self.assertEqual(payload["ink"], int(expected))
                with backend_app.task_lock:
                    self.assertEqual(
                        backend_app.task_store[payload["task_id"]]["ink"],
                        expected,
                    )
                with backend_app.queue_lock:
                    self.assertEqual(len(backend_app.task_queue), 1)

    def test_rejects_every_undocumented_ink_value_without_queueing(self):
        for value in ("", "true", "yes", "2", "-1"):
            with self.subTest(value=value):
                response = self.post_image(value)
                self.assertEqual(response.status_code, 400)
                self.assertEqual(
                    response.get_json(),
                    {"error": "invalid_ink"},
                )
        with backend_app.queue_lock:
            self.assertEqual(backend_app.task_queue, [])
        with backend_app.task_lock:
            self.assertEqual(backend_app.task_store, {})


class RecognitionResultTests(unittest.TestCase):
    def setUp(self):
        self.previous_proxy_mode = backend_app.TRUST_LOOPBACK_PROXY
        backend_app.TRUST_LOOPBACK_PROXY = True
        backend_app.app.config.update(TESTING=True)
        self.client = backend_app.app.test_client()
        with backend_app.task_lock:
            backend_app.task_store.clear()
            backend_app.task_store["test-task"] = {
                "status": "processing",
                "results": [],
                "recognition_results": [],
            }
        self.image = np.full((6, 9, 3), 90, dtype=np.uint8)

    def tearDown(self):
        backend_app.TRUST_LOOPBACK_PROXY = self.previous_proxy_mode
        with backend_app.task_lock:
            backend_app.task_store.clear()

    def test_ink_zero_returns_one_artifact_and_pattern(self):
        with mock.patch.object(
            backend_app,
            "classify_pattern",
            return_value="pattern3",
        ) as classify:
            polaroid_id, ink_id, pattern = (
                backend_app.add_processed_polaroid(
                    "test-task",
                    0,
                    self.image,
                    ink_enabled=False,
                    processor=object(),
                    model=object(),
                    device="cpu",
                )
            )

        self.assertEqual((polaroid_id, ink_id, pattern), (0, None, "pattern3"))
        classify.assert_called_once()
        with backend_app.task_lock:
            task = backend_app.task_store["test-task"]
            self.assertEqual(len(task["results"]), 1)
            self.assertEqual(task["results"][0]["type"], "polaroid")
            self.assertEqual(task["recognition_results"], [{
                "id": 0,
                "polaroid_result_id": 0,
                "ink_result_id": None,
                "date": None,
                "bbox": None,
                "pattern": "pattern3",
                "type": "polaroid",
                "label": "拍立得 #1",
            }])

    def test_ink_one_returns_two_byte_exact_artifacts_and_one_logical_result(self):
        ink_image = np.full((6, 9, 3), 255, dtype=np.uint8)
        ink_image[2:4, 3:6] = 0
        with (
            mock.patch.object(
                backend_app,
                "extract_ink_image",
                return_value=ink_image,
            ) as extract,
            mock.patch.object(
                backend_app,
                "classify_pattern",
                return_value="unassigned",
            ) as classify,
        ):
            polaroid_id, ink_id, pattern = (
                backend_app.add_processed_polaroid(
                    "test-task",
                    0,
                    self.image,
                    ink_enabled=True,
                    processor=object(),
                    model=object(),
                    device="cpu",
                )
            )

        self.assertEqual((polaroid_id, ink_id, pattern), (0, 1, "unassigned"))
        extract.assert_called_once()
        self.assertTrue(classify.call_args.kwargs["use_ink"])
        with backend_app.task_lock:
            task = backend_app.task_store["test-task"]
            self.assertEqual(len(task["results"]), 2)
            expected_polaroid = task["results"][0]["image_bytes"]
            expected_ink = task["results"][1]["image_bytes"]
            self.assertEqual(
                task["recognition_results"][0]["polaroid_result_id"],
                0,
            )
            self.assertEqual(
                task["recognition_results"][0]["ink_result_id"],
                1,
            )

        self.assertEqual(
            self.client.get(
                "/api/result/test-task/0"
            ).data,
            expected_polaroid,
        )
        self.assertEqual(
            self.client.get(
                "/api/result/test-task/1"
            ).data,
            expected_ink,
        )

    def test_status_exposes_logical_results_not_artifact_rows(self):
        with backend_app.task_lock:
            task = backend_app.task_store["test-task"]
            task.update({
                "status": "done",
                "phase": "complete",
                "recognition_results": [{
                    "id": 0,
                    "polaroid_result_id": 0,
                    "ink_result_id": 1,
                    "date": None,
                    "bbox": None,
                    "pattern": "pattern1",
                    "type": "polaroid",
                    "label": "拍立得 #1",
                }],
                "results": [
                    {
                        "id": 0,
                        "type": "polaroid",
                        "label": "拍立得 #1",
                        "image_bytes": b"a",
                        "mimetype": "image/png",
                    },
                    {
                        "id": 1,
                        "type": "ink",
                        "label": "墨迹 #1",
                        "image_bytes": b"b",
                        "mimetype": "image/png",
                    },
                ],
            })
        payload = self.client.get("/api/status/test-task").get_json()
        self.assertEqual(payload["results_count"], 1)
        self.assertEqual(payload["results"][0]["polaroid_result_id"], 0)
        self.assertEqual(payload["results"][0]["ink_result_id"], 1)
        self.assertEqual(payload["results"][0]["pattern"], "pattern1")


class RecognitionAssetBoundaryTests(unittest.TestCase):
    def test_missing_assets_use_only_a_fixed_error_code(self):
        variable_names = [
            polaroid_recognition.ASSETS_DIR_ENV,
            polaroid_recognition.RAW_GALLERY_ENV,
            polaroid_recognition.RAW_CHECKPOINT_ENV,
            polaroid_recognition.INK_GALLERY_ENV,
            polaroid_recognition.INK_CHECKPOINT_ENV,
        ]
        clean_environment = {
            key: value
            for key, value in os.environ.items()
            if key not in variable_names
        }
        with mock.patch.dict(os.environ, clean_environment, clear=True):
            with self.assertRaisesRegex(
                polaroid_recognition.RecognitionConfigurationError,
                "^pattern_assets_unavailable$",
            ):
                polaroid_recognition.configured_asset_paths(False)


class FakeMetricModel:
    def __init__(self, embedding):
        self.embedding = embedding

    def load_state_dict(self, _state):
        return None

    def to(self, _device):
        return self

    def eval(self):
        return self

    def __call__(self, _regions):
        return self.embedding.unsqueeze(0)


class PatternClassifierBoundaryTests(unittest.TestCase):
    @staticmethod
    def classifier(class_names, prototype_by_name, embedding):
        gallery = {
            "format": polaroid_recognition.GALLERY_FORMAT,
            "model_type": "test-model",
            "class_names": class_names,
            "prototypes": polaroid_recognition.torch.stack([
                prototype_by_name[name] for name in class_names
            ]),
            "rejection_threshold": 0.5,
        }
        checkpoint = {
            "model_type": "test-model",
            "model_state_dict": {},
        }
        model = FakeMetricModel(embedding)
        with (
            mock.patch.object(
                polaroid_recognition.torch,
                "load",
                side_effect=[gallery, checkpoint],
            ),
            mock.patch.object(
                polaroid_recognition,
                "MetricPatternEncoder",
                return_value=model,
            ),
        ):
            return polaroid_recognition.PatternClassifier(
                "gallery.pt",
                "checkpoint.pt",
                "cpu",
            )

    def test_excluded_patterns_never_compete_and_gallery_order_is_irrelevant(self):
        vectors = {
            "pattern1": polaroid_recognition.torch.tensor([0.20, 0.0]),
            "pattern2": polaroid_recognition.torch.tensor([0.90, 0.0]),
            "pattern7": polaroid_recognition.torch.tensor([1.00, 0.0]),
            "pattern11": polaroid_recognition.torch.tensor([0.99, 0.0]),
            "other": polaroid_recognition.torch.tensor([0.98, 0.0]),
        }
        image = np.zeros((4, 4, 3), dtype=np.uint8)
        orders = [
            ["pattern7", "pattern2", "pattern11", "pattern1", "other"],
            ["pattern1", "other", "pattern11", "pattern2", "pattern7"],
        ]
        for class_names in orders:
            with self.subTest(class_names=class_names):
                classifier = self.classifier(
                    class_names,
                    vectors,
                    polaroid_recognition.torch.tensor([1.0, 0.0]),
                )
                self.assertEqual(
                    set(classifier.class_names),
                    {"pattern1", "pattern2"},
                )
                with mock.patch.object(
                    polaroid_recognition,
                    "_image_to_metric_regions",
                    return_value=polaroid_recognition.torch.zeros(
                        3, 3, 2, 2
                    ),
                ):
                    self.assertEqual(
                        classifier.classify(image, grayscale=False),
                        "pattern2",
                    )

    def test_gallery_without_an_allowed_pattern_fails_closed(self):
        vectors = {
            "pattern7": polaroid_recognition.torch.tensor([1.0, 0.0]),
            "other": polaroid_recognition.torch.tensor([0.5, 0.5]),
        }
        with self.assertRaisesRegex(
            polaroid_recognition.RecognitionConfigurationError,
            "^pattern_assets_invalid$",
        ):
            self.classifier(
                ["pattern7", "other"],
                vectors,
                polaroid_recognition.torch.tensor([1.0, 0.0]),
            )

    def test_raw_and_ink_paths_keep_their_existing_grayscale_behavior(self):
        image = np.zeros((4, 4, 3), dtype=np.uint8)
        raw_classifier = mock.Mock()
        raw_classifier.classify.return_value = "pattern1"
        ink_classifier = mock.Mock()
        ink_classifier.classify.return_value = "pattern6"

        def selected_classifier(use_ink, _device):
            return ink_classifier if use_ink else raw_classifier

        with mock.patch.object(
            polaroid_recognition,
            "_classifier",
            side_effect=selected_classifier,
        ):
            self.assertEqual(
                polaroid_recognition.classify_pattern(
                    image,
                    use_ink=False,
                    device="cpu",
                ),
                "pattern1",
            )
            self.assertEqual(
                polaroid_recognition.classify_pattern(
                    image,
                    use_ink=True,
                    device="cpu",
                ),
                "pattern6",
            )

        raw_classifier.classify.assert_called_once_with(
            image,
            grayscale=False,
        )
        ink_classifier.classify.assert_called_once_with(
            image,
            grayscale=True,
        )


class FakeHTTPResponse(io.BytesIO):
    def __init__(self, payload, status=200):
        super().__init__(json.dumps(payload).encode("utf-8"))
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()
        return False


class DateAnnotationCallbackTests(unittest.TestCase):
    def test_callback_sends_only_ids_once_and_selects_ink_artifact(self):
        captured = []

        def opener(request, timeout):
            captured.append((request, timeout))
            return FakeHTTPResponse({
                "status": "done",
                "results": [
                    {
                        "id": 0,
                        "date": "2026.07.26",
                        "bbox": [1, 2, 30, 40],
                    },
                    {"id": 1, "date": None, "bbox": None},
                ],
            })

        environment = {
            date_annotation_callback.CALLBACK_BASE_ENV:
                "http://127.0.0.1:8787",
            date_annotation_callback.CALLBACK_TOKEN_ENV:
                "local-callback-test-token-0123",
        }
        with mock.patch.dict(os.environ, environment, clear=False):
            annotations = (
                date_annotation_callback.request_task_date_annotations(
                    "0123456789abcdef0123456789abcdef",
                    [
                        {
                            "id": 0,
                            "polaroid_result_id": 4,
                            "ink_result_id": 5,
                        },
                        {
                            "id": 1,
                            "polaroid_result_id": 6,
                            "ink_result_id": None,
                        },
                    ],
                    "unused-access-token-012345",
                    urlopen_impl=opener,
                )
            )

        self.assertEqual(len(captured), 1)
        callback_request, timeout = captured[0]
        self.assertEqual(
            timeout,
            date_annotation_callback.DEFAULT_TIMEOUT_SECONDS,
        )
        self.assertGreaterEqual(timeout, 120)
        request_body = json.loads(callback_request.data.decode("utf-8"))
        self.assertEqual(request_body, {
            "task_id": "0123456789abcdef0123456789abcdef",
            "results": [
                {"id": 0, "artifact_id": 5},
                {"id": 1, "artifact_id": 6},
            ],
        })
        self.assertNotIn("image", json.dumps(request_body))
        self.assertIsNotNone(
            callback_request.get_header("X-cheki-token")
        )
        self.assertEqual(annotations[0]["date"], "2026.07.26")
        self.assertEqual(annotations[1]["date"], None)

    def test_backend_persists_one_callback_response_before_done_status(self):
        task_id = "fedcba9876543210fedcba9876543210"
        with backend_app.task_lock:
            backend_app.task_store.clear()
            backend_app.task_store[task_id] = {
                "status": "processing",
                "phase": "recognizing_date",
                "recognition_results": [
                    {
                        "id": 0,
                        "polaroid_result_id": 0,
                        "ink_result_id": None,
                        "date": None,
                        "bbox": None,
                        "pattern": "pattern1",
                        "type": "polaroid",
                        "label": "拍立得 #1",
                    },
                ],
            }
        with mock.patch.object(
            backend_app,
            "request_task_date_annotations",
            return_value=[{
                "id": 0,
                "date": "07.26",
                "bbox": [10, 20, 30, 40],
            }],
        ) as callback:
            backend_app.annotate_task_results(task_id)

        callback.assert_called_once()
        with backend_app.task_lock:
            result = backend_app.task_store[
                task_id
            ]["recognition_results"][0]
            self.assertEqual(result["date"], "07.26")
            self.assertEqual(result["bbox"], [10, 20, 30, 40])
            self.assertEqual(
                backend_app.task_store[task_id]["status"],
                "processing",
            )
            backend_app.task_store.clear()

    def test_callback_failure_uses_only_fixed_error(self):
        environment = {
            date_annotation_callback.CALLBACK_BASE_ENV:
                "http://127.0.0.1:8787",
            date_annotation_callback.CALLBACK_TOKEN_ENV:
                "local-callback-test-token-0123",
        }
        with mock.patch.dict(os.environ, environment, clear=False):
            with self.assertRaisesRegex(
                date_annotation_callback.DateAnnotationUnavailable,
                "^date_annotation_unavailable$",
            ):
                date_annotation_callback.request_task_date_annotations(
                    "0123456789abcdef0123456789abcdef",
                    [{
                        "id": 0,
                        "polaroid_result_id": 0,
                        "ink_result_id": None,
                    }],
                    "unused-access-token-012345",
                    urlopen_impl=lambda *_args, **_kwargs: (
                        (_ for _ in ()).throw(
                            RuntimeError("private network detail")
                        )
                    ),
                )


if __name__ == "__main__":
    unittest.main()
