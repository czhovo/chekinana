#!/usr/bin/env python3
"""Generate synthetic OpenCV glue fixtures for ChekiEdgeFit-RT v2."""

from __future__ import annotations

import argparse
import base64
import json
import math
from pathlib import Path

import cv2
import numpy as np


PAD_RGB = (123.675, 116.28, 103.53)


def encoded(values: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(values).tobytes()).decode("ascii")


def synthetic_rgb(height: int, width: int, seed: int) -> np.ndarray:
    y, x, channel = np.indices((height, width, 3), dtype=np.int64)
    return (
        x * 37 + y * 61 + channel * 83 + x * y * 7
        + (x * x + y * y) * 3 + seed
    ).astype(np.uint8)


def resize_case(
    name: str,
    size: tuple[int, int],
    output: tuple[int, int],
    interpolation: int,
) -> dict:
    width, height = size
    source = synthetic_rgb(height, width, len(name) * 11)
    result = cv2.resize(source, output, interpolation=interpolation)
    return {
        "name": name,
        "width": width,
        "height": height,
        "outputWidth": output[0],
        "outputHeight": output[1],
        "inputBase64": encoded(source),
        "expectedBase64": encoded(result),
    }


def square20(box: np.ndarray) -> np.ndarray:
    box = np.asarray(box, np.float64)
    center = (box[:2] + box[2:]) / 2
    side = max(box[2] - box[0], box[3] - box[1], 2.0) * 1.4
    return np.asarray(
        [
            center[0] - side / 2,
            center[1] - side / 2,
            center[0] + side / 2,
            center[1] + side / 2,
        ],
        np.float64,
    )


def warp_case(name: str, size: tuple[int, int], box: list[float]) -> dict:
    width, height = size
    source = synthetic_rgb(height, width, len(name) * 17)
    roi = square20(np.asarray(box, np.float32))
    side = float(roi[2] - roi[0])
    crop_side = max(64, int(round(side)))
    source_quad = np.asarray(
        [[roi[0], roi[1]], [roi[2], roi[1]], [roi[2], roi[3]], [roi[0], roi[3]]],
        np.float32,
    )
    destination_quad = np.asarray(
        [
            [0, 0], [crop_side - 1, 0],
            [crop_side - 1, crop_side - 1], [0, crop_side - 1],
        ],
        np.float32,
    )
    matrix = cv2.getPerspectiveTransform(source_quad, destination_quad)
    result = cv2.warpPerspective(
        source,
        matrix,
        (crop_side, crop_side),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=PAD_RGB,
    )
    return {
        "name": name,
        "width": width,
        "height": height,
        "box": box,
        "cropSide": crop_side,
        "borderRGB": list(PAD_RGB),
        "inputBase64": encoded(source),
        "expectedBase64": encoded(result),
    }


def coarse_case(name: str, box: list[float], phase: float) -> dict:
    y, x = np.indices((56, 56), dtype=np.float32)
    logits = (
        np.sin(x * np.float32(0.31) + np.float32(phase)) * np.float32(3.2)
        + np.cos(y * np.float32(0.27) - np.float32(phase)) * np.float32(2.4)
        + np.sin((x + y) * np.float32(0.11)) * np.float32(1.3)
    ).astype(np.float32)
    quantized = logits.astype(np.float16).astype(np.float32)
    probability = (np.float32(1) / (np.float32(1) + np.exp(-quantized))).astype(
        np.float32
    )
    scaled = np.asarray(box, np.float64) / 4.0
    x1, y1, x2, y2 = scaled
    width = max(int(math.ceil(x2) - math.floor(x1)), 1)
    height = max(int(math.ceil(y2) - math.floor(y1)), 1)
    resized = cv2.resize(
        probability, (width, height), interpolation=cv2.INTER_LINEAR
    )
    pasted = np.zeros((192, 192), dtype=np.float32)
    left, top = int(math.floor(x1)), int(math.floor(y1))
    right, bottom = left + width, top + height
    output_x1, output_y1 = max(left, 0), max(top, 0)
    output_x2, output_y2 = min(right, 192), min(bottom, 192)
    if output_x2 > output_x1 and output_y2 > output_y1:
        source_x1, source_y1 = output_x1 - left, output_y1 - top
        source_x2 = source_x1 + output_x2 - output_x1
        source_y2 = source_y1 + output_y2 - output_y1
        pasted[output_y1:output_y2, output_x1:output_x2] = resized[
            source_y1:source_y2, source_x1:source_x2
        ]
    binary = (pasted >= np.float32(0.5)).astype(np.uint8)
    return {
        "name": name,
        "box": box,
        "logitsFloat32Base64": encoded(quantized),
        "expectedMaskBase64": encoded(binary),
    }


def soft_support_case(name: str, box: list[float], phase: float) -> dict:
    y, x = np.indices((56, 56), dtype=np.float32)
    logits = (
        np.sin(x * np.float32(0.23) + np.float32(phase)) * np.float32(2.7)
        + np.cos(y * np.float32(0.19) - np.float32(phase)) * np.float32(1.9)
        + np.sin((x - y) * np.float32(0.07)) * np.float32(0.8)
    ).astype(np.float32)
    probability = (
        np.float32(1)
        / (np.float32(1) + np.exp(-logits.astype(np.float16).astype(np.float32)))
    ).astype(np.float32)
    left, top = int(math.floor(box[0])), int(math.floor(box[1]))
    right, bottom = int(math.ceil(box[2])), int(math.ceil(box[3]))
    target_width = max(right - left, 1)
    target_height = max(bottom - top, 1)
    resized = cv2.resize(
        probability,
        (target_width, target_height),
        interpolation=cv2.INTER_LINEAR,
    )
    canvas = 768
    x1, y1 = max(left, 0), max(top, 0)
    x2, y2 = min(right, canvas), min(bottom, canvas)
    support = resized[y1 - top : y2 - top, x1 - left : x2 - left].copy()
    area = np.float32(0)
    for value in support.reshape(-1):
        area = np.float32(area + value)
    return {
        "name": name,
        "box": box,
        "canvas": canvas,
        "expectedBounds": [x1, y1, x2, y2],
        "probabilityFloat32Base64": encoded(probability),
        "expectedSupportFloat32Base64": encoded(support),
        "expectedArea": float(area),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    fixture = {
        "schema": "chekiedgefit-rt-v2-opencv-math-fixture-1",
        "opencv": cv2.__version__,
        "areaResizeRGB": [
            resize_case("integer-2x-down", (8, 6), (4, 3), cv2.INTER_AREA),
            resize_case("noninteger-down", (17, 11), (8, 5), cv2.INTER_AREA),
            resize_case("noninteger-up", (7, 5), (11, 9), cv2.INTER_AREA),
        ],
        "linearResizeRGB": [
            resize_case("noninteger-down", (19, 13), (8, 6), cv2.INTER_LINEAR),
            resize_case("noninteger-up", (7, 5), (13, 9), cv2.INTER_LINEAR),
        ],
        "square20WarpRGB": [
            warp_case("inside", (247, 181), [54.5, 29.25, 154.75, 128.5]),
            warp_case("outside-fractional", (247, 181), [10.25, 5.5, 222.75, 156.0]),
        ],
        "coarseMasks": [
            coarse_case("in-bounds", [116.4, 143.2, 596.7, 664.9], 0.37),
            coarse_case("clipped-outside", [-85.75, 490.2, 251.6, 842.9], 1.13),
        ],
        "softMaskSupports": [
            soft_support_case(
                "mixed-scale-clipped",
                [-7.25, 705.6, 70.4, 775.3],
                0.61,
            ),
        ],
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
