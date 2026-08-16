"""Ink extraction and fixed-person pattern recognition for cropped Polaroids.

Model assets are intentionally external to the checkout. Configure either the
four explicit asset variables or an assets directory containing:

- raw_gallery.pt
- raw_metric_encoder.pt
- ink_grayscale_gallery.pt
- ink_grayscale_metric_encoder.pt
"""

from __future__ import annotations

import os
import threading
from pathlib import Path

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as torch_f
from PIL import Image, ImageOps


ASSETS_DIR_ENV = "CHEKINANA_PATTERN_ASSETS_DIR"
RAW_GALLERY_ENV = "CHEKINANA_PATTERN_RAW_GALLERY"
RAW_CHECKPOINT_ENV = "CHEKINANA_PATTERN_RAW_CHECKPOINT"
INK_GALLERY_ENV = "CHEKINANA_PATTERN_INK_GALLERY"
INK_CHECKPOINT_ENV = "CHEKINANA_PATTERN_INK_CHECKPOINT"
INK_PROMPT_ENV = "CHEKINANA_INK_PROMPT"

GALLERY_FORMAT = "fixed_person_prototype_gallery_v1"
KNOWN_PATTERNS = frozenset({
    "pattern1",
    "pattern2",
    "pattern3",
    "pattern4",
    "pattern5",
    "pattern6",
})
UNASSIGNED_PATTERN = "unassigned"

IMAGE_SIZE = 192
EMBEDDING_DIM = 256
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]
REGION_BOXES_NORMALIZED = (
    (0.00, 0.00, 1.00, 1.00),
    (0.00, 0.43, 1.00, 1.00),
    (0.12, 0.48, 0.88, 1.00),
)
REGION_WEIGHTS = (0.20, 0.42, 0.38)

INK_BASE_SIZE = np.array([800.0, 1272.0], dtype=np.float64)
INK_BASE_AREA = np.array(
    [[55, 100], [745, 100], [745, 1022], [55, 1022]],
    dtype=np.float64,
)
INK_PROBE_THRESHOLDS = (0.5, 0.4, 0.3, 0.2, 0.1)
INK_THRESHOLD_RATIOS = (0.79, 0.62, 0.49, 0.39, 0.31, 0.24, 0.19, 0.15)
INK_OUTLINE_DISTANCE = 20


class RecognitionConfigurationError(RuntimeError):
    """A fixed, non-sensitive recognition configuration failure."""


class RecognitionRuntimeError(RuntimeError):
    """A fixed, non-sensitive recognition inference failure."""


def _configured_path(explicit_name: str, fallback_name: str) -> Path:
    explicit = os.environ.get(explicit_name, "").strip()
    if explicit:
        candidate = Path(explicit)
    else:
        assets_dir = os.environ.get(ASSETS_DIR_ENV, "").strip()
        if not assets_dir:
            raise RecognitionConfigurationError("pattern_assets_unavailable")
        candidate = Path(assets_dir) / fallback_name
    try:
        return candidate.expanduser().resolve(strict=True)
    except (OSError, RuntimeError):
        raise RecognitionConfigurationError(
            "pattern_assets_unavailable"
        ) from None


def configured_asset_paths(use_ink: bool) -> tuple[Path, Path]:
    if use_ink:
        return (
            _configured_path(INK_GALLERY_ENV, "ink_grayscale_gallery.pt"),
            _configured_path(
                INK_CHECKPOINT_ENV,
                "ink_grayscale_metric_encoder.pt",
            ),
        )
    return (
        _configured_path(RAW_GALLERY_ENV, "raw_gallery.pt"),
        _configured_path(RAW_CHECKPOINT_ENV, "raw_metric_encoder.pt"),
    )


def _region_boxes(width: int, height: int) -> list[tuple[int, int, int, int]]:
    boxes = []
    for x1, y1, x2, y2 in REGION_BOXES_NORMALIZED:
        left = min(width - 1, max(0, int(round(width * x1))))
        top = min(height - 1, max(0, int(round(height * y1))))
        right = min(width, max(left + 1, int(round(width * x2))))
        bottom = min(height, max(top + 1, int(round(height * y2))))
        boxes.append((left, top, right, bottom))
    return boxes


def _image_to_metric_regions(image: Image.Image) -> torch.Tensor:
    try:
        from torchvision.transforms import InterpolationMode
        from torchvision.transforms import functional as vision_f
    except ImportError:
        raise RecognitionConfigurationError(
            "pattern_runtime_unavailable"
        ) from None

    tensors = []
    for box in _region_boxes(*image.size):
        region = image.crop(box)
        region = vision_f.resize(
            region,
            [IMAGE_SIZE, IMAGE_SIZE],
            interpolation=InterpolationMode.BICUBIC,
            antialias=True,
        )
        tensor = vision_f.pil_to_tensor(region).float().div_(255.0)
        tensor = vision_f.normalize(tensor, IMAGENET_MEAN, IMAGENET_STD)
        tensors.append(tensor)
    return torch.stack(tensors)


class MetricPatternEncoder(nn.Module):
    def __init__(
        self,
        embedding_dim: int = EMBEDDING_DIM,
        region_weights=REGION_WEIGHTS,
    ):
        super().__init__()
        try:
            from torchvision.models import resnet18
        except ImportError:
            raise RecognitionConfigurationError(
                "pattern_runtime_unavailable"
            ) from None

        backbone = resnet18(weights=None)
        self.backbone = nn.Sequential(*list(backbone.children())[:-1])
        weights_tensor = torch.tensor(region_weights, dtype=torch.float32)
        weights_tensor = weights_tensor / weights_tensor.sum()
        self.register_buffer(
            "region_weights",
            weights_tensor,
            persistent=False,
        )
        self.projector = nn.Sequential(
            nn.Linear(512, 512),
            nn.ReLU(inplace=True),
            nn.Dropout(0.15),
            nn.Linear(512, embedding_dim),
        )

    def forward(self, regions: torch.Tensor) -> torch.Tensor:
        batch_size, region_count, channels, height, width = regions.shape
        if region_count != len(self.region_weights):
            raise RecognitionRuntimeError("pattern_inference_failed")
        features = self.backbone(
            regions.reshape(
                batch_size * region_count,
                channels,
                height,
                width,
            )
        )
        features = features.flatten(1).reshape(
            batch_size,
            region_count,
            512,
        )
        pooled = (
            features
            * self.region_weights.view(1, region_count, 1)
        ).sum(dim=1)
        return torch_f.normalize(self.projector(pooled), dim=1)


class PatternClassifier:
    def __init__(
        self,
        gallery_path: Path,
        checkpoint_path: Path,
        device,
    ):
        try:
            gallery = torch.load(
                gallery_path,
                map_location="cpu",
                weights_only=True,
            )
            checkpoint = torch.load(
                checkpoint_path,
                map_location="cpu",
                weights_only=True,
            )
            class_names = list(gallery["class_names"])
            if gallery.get("format") != GALLERY_FORMAT:
                raise ValueError
            if gallery.get("model_type") != checkpoint.get("model_type"):
                raise ValueError
            if not class_names or any(
                not isinstance(name, str) for name in class_names
            ):
                raise ValueError

            prototypes = gallery["prototypes"].float()
            if (
                prototypes.ndim != 2
                or prototypes.shape[0] != len(class_names)
            ):
                raise ValueError
            allowed_indexes = [
                index
                for index, name in enumerate(class_names)
                if name in KNOWN_PATTERNS
            ]
            if not allowed_indexes:
                raise ValueError
            prototypes = prototypes[allowed_indexes]
            class_names = [
                class_names[index] for index in allowed_indexes
            ]
            model = MetricPatternEncoder(
                embedding_dim=int(
                    checkpoint.get("embedding_dim", EMBEDDING_DIM)
                ),
                region_weights=checkpoint.get(
                    "region_weights",
                    REGION_WEIGHTS,
                ),
            )
            model.load_state_dict(checkpoint["model_state_dict"])
        except RecognitionConfigurationError:
            raise
        except Exception:
            raise RecognitionConfigurationError(
                "pattern_assets_invalid"
            ) from None

        self.device = torch.device(device)
        self.model = model.to(self.device).eval()
        self.prototypes = prototypes.to(self.device)
        self.class_names = class_names
        self.threshold = float(gallery["rejection_threshold"])

    @torch.no_grad()
    def classify(self, image_rgb: np.ndarray, grayscale: bool) -> str:
        image = Image.fromarray(image_rgb).convert("RGB")
        if grayscale:
            image = ImageOps.grayscale(image).convert("RGB")
        try:
            regions = _image_to_metric_regions(image).unsqueeze(0).to(
                self.device
            )
            embedding = self.model(regions)[0]
            scores = embedding @ self.prototypes.T
            best_score, best_index = scores.max(dim=0)
            if float(best_score) < self.threshold:
                return UNASSIGNED_PATTERN
            pattern = self.class_names[int(best_index)]
            return (
                pattern
                if pattern in KNOWN_PATTERNS
                else UNASSIGNED_PATTERN
            )
        except RecognitionConfigurationError:
            raise
        except Exception:
            raise RecognitionRuntimeError(
                "pattern_inference_failed"
            ) from None
        finally:
            image.close()


_classifier_cache: dict[tuple[str, str, str], PatternClassifier] = {}
_classifier_lock = threading.Lock()


def _classifier(use_ink: bool, device) -> PatternClassifier:
    gallery_path, checkpoint_path = configured_asset_paths(use_ink)
    key = (str(gallery_path), str(checkpoint_path), str(device))
    with _classifier_lock:
        classifier = _classifier_cache.get(key)
        if classifier is None:
            classifier = PatternClassifier(
                gallery_path,
                checkpoint_path,
                device,
            )
            _classifier_cache[key] = classifier
        return classifier


def classify_pattern(
    image_rgb: np.ndarray,
    *,
    use_ink: bool,
    device,
) -> str:
    return _classifier(use_ink, device).classify(
        image_rgb,
        grayscale=use_ink,
    )


def _scaled_ink_area(width: int, height: int) -> np.ndarray:
    scale = np.array(
        [width / INK_BASE_SIZE[0], height / INK_BASE_SIZE[1]],
        dtype=np.float64,
    )
    return INK_BASE_AREA * scale


def _build_ink_regions(
    shape,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    height, width = shape[:2]
    area_vertices = _scaled_ink_area(width, height).astype(np.int32)
    image_area_mask = np.zeros((height, width), dtype=np.uint8)
    cv2.fillPoly(image_area_mask, [area_vertices], 1)
    image_area_mask = image_area_mask.astype(bool)

    scale = max(
        width / INK_BASE_SIZE[0],
        height / INK_BASE_SIZE[1],
    )
    kernel_size = max(3, int(round(21 * scale)))
    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = cv2.getStructuringElement(
        cv2.MORPH_ELLIPSE,
        (kernel_size, kernel_size),
    )
    dilated = cv2.dilate(
        image_area_mask.astype(np.uint8),
        kernel,
        iterations=1,
    ).astype(bool)
    eroded = cv2.erode(
        image_area_mask.astype(np.uint8),
        kernel,
        iterations=1,
    ).astype(bool)
    return ~dilated, eroded, dilated ^ eroded


def _postprocess_ink_masks(
    processor,
    outputs,
    thresholds,
    target_size,
) -> list[np.ndarray]:
    masks = []
    for threshold in thresholds:
        result = processor.post_process_instance_segmentation(
            outputs,
            threshold=threshold,
            mask_threshold=0.5,
            target_sizes=[target_size],
        )[0]
        if len(result["masks"]) == 0:
            masks.append(np.zeros(target_size, dtype=bool))
        else:
            masks.append(
                np.any(result["masks"].cpu().numpy(), axis=0)
            )
    return masks


def _ink_stopping_rule(
    current_pixels: int,
    total_area_ratio: float,
    border_area_ratio: float,
    border_match_ratio: float,
    image_area_ratio: float,
    image_match_ratio: float,
) -> str:
    if current_pixels > 0 and total_area_ratio < 0.015:
        return "reject"
    if (
        border_area_ratio > 0.15
        and (border_area_ratio > 0.50 or border_match_ratio > 0.50)
    ) or (
        image_area_ratio > 0.15
        and (image_area_ratio > 0.50 or image_match_ratio > 0.50)
    ):
        return "accept"
    if (
        border_area_ratio > 0.015 and border_match_ratio < 0.80
    ) or (
        image_area_ratio > 0.015 and image_match_ratio < 0.80
    ):
        return "reject"
    return "accept"


def extract_ink_image(
    image_rgb: np.ndarray,
    processor,
    model,
    device,
) -> np.ndarray:
    """Return original ink pixels on white, preserving input dimensions."""
    try:
        height, width = image_rgb.shape[:2]
        border_region, image_region, excluded = _build_ink_regions(
            image_rgb.shape
        )
        pil_image = Image.fromarray(image_rgb)
        prompt = os.environ.get(INK_PROMPT_ENV, "scribble").strip()
        if not prompt:
            prompt = "scribble"
        inputs = processor(
            images=pil_image,
            text=prompt,
            return_tensors="pt",
        ).to(device)
        with torch.no_grad():
            outputs = model(**inputs)

        base_threshold = None
        for threshold in INK_PROBE_THRESHOLDS:
            result = processor.post_process_instance_segmentation(
                outputs,
                threshold=threshold,
                mask_threshold=0.5,
                target_sizes=[(height, width)],
            )[0]
            if len(result["masks"]) > 0 and base_threshold is None:
                index = INK_PROBE_THRESHOLDS.index(threshold)
                base_threshold = (
                    INK_PROBE_THRESHOLDS[index - 1]
                    if index > 0
                    else 0.6338
                )
        if base_threshold is None:
            base_threshold = 0.1

        thresholds = [
            base_threshold * ratio
            for ratio in INK_THRESHOLD_RATIOS
        ]
        masks = _postprocess_ink_masks(
            processor,
            outputs,
            thresholds,
            (height, width),
        )
        del inputs, outputs

        stop_index = len(INK_THRESHOLD_RATIOS)
        outline_distance = max(
            1,
            int(round(
                INK_OUTLINE_DISTANCE
                * max(
                    width / INK_BASE_SIZE[0],
                    height / INK_BASE_SIZE[1],
                )
            )),
        )
        for threshold_index, current_mask in enumerate(masks):
            if threshold_index == 0:
                continue
            previous_mask = masks[threshold_index - 1]
            new_pixels_raw = current_mask & ~previous_mask
            previous_count = int(previous_mask.sum())
            if previous_count > 0:
                previous_boundary = cv2.Canny(
                    (previous_mask & ~excluded).astype(np.uint8) * 255,
                    0,
                    1,
                ) > 0
                distance = cv2.distanceTransform(
                    (~previous_boundary).astype(np.uint8),
                    cv2.DIST_L2,
                    5,
                )
                new_pixels = new_pixels_raw & (
                    distance >= outline_distance
                )
            else:
                new_pixels = new_pixels_raw

            previous_border = previous_mask & border_region
            previous_image = previous_mask & image_region
            new_border = new_pixels & border_region
            new_image = new_pixels & image_region
            new_border_raw = new_pixels_raw & border_region
            new_image_raw = new_pixels_raw & image_region

            def match_ratio(raw_mask, previous_region) -> float:
                raw_count = int(raw_mask.sum())
                previous_region_count = int(previous_region.sum())
                if raw_count == 0:
                    return 1.0
                if previous_region_count == 0:
                    return 1.0
                previous_pixels = image_rgb[
                    previous_region
                ].astype(float)
                mean = previous_pixels.mean(axis=0)
                stddev = previous_pixels.std(axis=0)
                new_values = image_rgb[raw_mask].astype(float)
                score = np.abs(
                    (new_values - mean) / (stddev + 1e-6)
                ).mean(axis=1)
                return float((score < 2.0).sum()) / raw_count

            new_border_count = int(new_border.sum())
            new_image_count = int(new_image.sum())
            previous_border_count = int(previous_border.sum())
            previous_image_count = int(previous_image.sum())
            border_area_ratio = (
                new_border_count
                / (previous_border_count + new_border_count)
                if previous_border_count + new_border_count > 0
                else 0.0
            )
            image_area_ratio = (
                new_image_count
                / (previous_image_count + new_image_count)
                if previous_image_count + new_image_count > 0
                else 0.0
            )
            current_count = int(current_mask.sum())
            total_area_ratio = (
                int(new_pixels.sum()) / current_count
                if current_count > 0
                else 0.0
            )
            decision = _ink_stopping_rule(
                current_count,
                total_area_ratio,
                border_area_ratio,
                match_ratio(new_border_raw, previous_border),
                image_area_ratio,
                match_ratio(new_image_raw, previous_image),
            )
            if (
                stop_index == len(INK_THRESHOLD_RATIOS)
                and decision == "reject"
            ):
                stop_index = threshold_index

        used_index = max(0, stop_index - 1)
        ink_mask = masks[used_index]
        ink_image = np.full_like(image_rgb, 255)
        ink_image[ink_mask] = image_rgb[ink_mask]
        return ink_image
    except RecognitionConfigurationError:
        raise
    except Exception:
        raise RecognitionRuntimeError("ink_extraction_failed") from None
    finally:
        if "pil_image" in locals():
            pil_image.close()
        if str(device).startswith("cuda") and torch.cuda.is_available():
            torch.cuda.empty_cache()
