#!/usr/bin/env python3
"""Generate redistributable Pillow/NumPy/OpenCV ChekiEdgeFit-RT v2 fixtures."""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
from pathlib import Path

import cv2
import numpy as np
import PIL
from PIL import Image
from scipy.spatial import ConvexHull


def load_reference(path: Path):
    spec = importlib.util.spec_from_file_location("ransac_quadrilateral", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def encoded(values: np.ndarray) -> str:
    return base64.b64encode(values.astype(np.uint8).tobytes()).decode("ascii")


def resize_sample(name: str, height: int, width: int, output: tuple[int, int]):
    y, x, channel = np.indices((height, width, 3), dtype=np.int64)
    source = ((x * 37 + y * 61 + channel * 83 + x * y * 7 + 11) % 256).astype(
        np.uint8
    )
    result = np.asarray(
        Image.fromarray(source, "RGB").resize(output, Image.Resampling.BILINEAR)
    )
    return {
        "name": name,
        "width": width,
        "height": height,
        "outputWidth": output[0],
        "outputHeight": output[1],
        "inputBase64": encoded(source),
        "expectedBase64": encoded(result),
    }


def initial_quad(mask: np.ndarray) -> np.ndarray:
    contours, _ = cv2.findContours(
        mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE
    )
    points = np.vstack([contour.reshape(-1, 2) for contour in contours])
    hull = ConvexHull(points)
    hull_points = points[hull.vertices]
    rectangle = cv2.minAreaRect(hull_points.astype(np.float32))
    quad = cv2.boxPoints(rectangle)
    center = quad.mean(axis=0)
    angles = np.arctan2(quad[:, 1] - center[1], quad[:, 0] - center[0])
    return quad[np.argsort(angles)].astype(np.float64)


def mask_sample(name: str, mask: np.ndarray, reference):
    contours, _ = cv2.findContours(
        mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE
    )
    contour_points = np.vstack([contour.reshape(-1, 2) for contour in contours])
    return {
        "name": name,
        "width": int(mask.shape[1]),
        "height": int(mask.shape[0]),
        "maskBase64": encoded(mask),
        "contourPoints": contour_points.astype(int).tolist(),
        "initialQuadrilateral": initial_quad(mask).tolist(),
        "finalQuadrilateral": reference.mask_to_quad_ransac(mask).tolist(),
        "initialTolerance": 1e-4,
        "finalTolerance": 1e-4,
    }


def masks():
    first = np.zeros((96, 128), dtype=np.uint8)
    cv2.fillPoly(
        first,
        [
            np.array(
                [
                    [18, 13], [55, 9], [104, 20], [111, 55], [96, 82],
                    [50, 88], [14, 71], [10, 35], [21, 31], [16, 25],
                ],
                dtype=np.int32,
            )
        ],
        1,
    )

    second = np.zeros((104, 144), dtype=np.uint8)
    polygon = np.array(
        [
            [31, 8], [100, 17], [128, 43], [119, 84], [75, 96], [23, 77],
            [15, 48], [26, 43], [20, 37], [34, 34], [27, 26], [39, 23],
        ],
        dtype=np.int32,
    )
    cv2.fillPoly(second, [polygon], 1)
    return [("jagged-perspective-a", first), ("jagged-perspective-b", second)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ransac-source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    reference = load_reference(arguments.ransac_source)

    choice = []
    for population in (5, 6, 8, 10, 32, 100, 1000):
        generator = np.random.default_rng(42)
        count = min(5, population)
        choice.append(
            {
                "upperBound": population,
                "count": count,
                "expected": [
                    generator.choice(
                        population, count, replace=False
                    ).astype(int).tolist()
                    for _ in range(8)
                ],
            }
        )

    fixture = {
        "schema": "chekiedgefit-rt-v2-reference-math-fixture-1",
        "versions": {
            "numpy": np.__version__,
            "opencv": cv2.__version__,
            "pillow": PIL.__version__,
        },
        "numpyChoice": choice,
        "pillowBilinearRGB": [
            resize_sample("downsample-both", 11, 17, (8, 5)),
            resize_sample("downsample-tall", 29, 7, (5, 17)),
            resize_sample("upsample-longest-side", 5, 9, (16, 9)),
        ],
        "ransacMasks": [mask_sample(name, mask, reference) for name, mask in masks()],
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
