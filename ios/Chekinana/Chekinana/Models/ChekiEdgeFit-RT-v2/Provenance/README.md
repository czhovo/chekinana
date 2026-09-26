# ChekiEdgeFit-RT v2 Core ML FP32 Delivery

Asset version: `cefrt2-fp32-20260903.1`.
Frozen production models: RT-DETR-R18 epoch 24 and EdgeSAM-3x epoch 10.
Global object threshold: **0.9267578125**. No NMS, selector, ACR, or fallback.

## Delivered Models

| Package | Purpose | Stored size |
| --- | --- | ---: |
| `Models/CEFRT2Detector.mlpackage` | RT-DETR, all 300 raw queries | 77.56 MiB |
| `Models/CEFRT2EdgeSAMEncoder.mlpackage` | One square20 crop to image embedding | 21.15 MiB |
| `Models/CEFRT2EdgeSAMBoxDecoder.mlpackage` | Box prompt and embedding to one mask | 23.59 MiB |

These are actual ML Program packages, not placeholders. All neural floating-point computation and tensor I/O are FP32. The minimum target is iOS 17 / macOS 14. Two production networks are split into three Core ML components so the EdgeSAM embedding is explicit. No training checkpoint or private image dataset is included.

## Validation Status

- Actual conversion, save/reopen, tensor shapes/names, graph FP32 inspection, package hashes: passed.
- Windows eager FP32 versus exported TorchScript on six synthetic cases: passed.
- Linux PyTorch 2.1.2 execution of those TorchScript files versus the same full-tensor references: passed.
- Core ML compilation/prediction on macOS and iPhone: **not tested on this Windows/WSL host**.
- Swift adapter/XCTest compilation: not tested here; source is supplied for Mac integration.
- End-to-end Swift image preprocessing/G parity, iPhone latency, memory and ANE/GPU behavior: not validated.

This is an **export-ready model delivery**, not a claim of verified iPhone deployment. See `NUMERIC_VALIDATION_REPORT.md` for measured errors. Synthetic tensor checks do not establish image-level or geometric equivalence.

## Integration

Read **`INTEGRATION_CONTRACT.md`** before wiring the models. Detector inputs are already normalized 768-square tensors. Encoder inputs are already SAM-normalized 1024-square tensors. The box decoder takes XYXY pixel coordinates on the resized 1024 crop. None of the three packages performs full image preprocessing or frozen G.

`Sources/ChekiEdgeFitRT/FP32Component.swift` is a tensor-only adapter that checks names, dimensions and FP32 types, preserves output strides, and uses CPU-only Core ML for initial validation. It does not silently switch to FP16 or implement a replacement G. Add the three packages to the application target so Xcode compiles/bundles them; this Swift package intentionally does not duplicate model assets as library resources.

On a Mac with Xcode and the macOS 14+ SDK, run from this extracted directory:

```sh
swift test
```

The test compiles the actual packages and compares every output element of all six fixtures. Fixture identity is SHA-256 checked. `CEFRT2_DELIVERY_DIR` can override the root for an Xcode test target. Do not relax tolerances to hide failures.

The Python verifier is an alternative and emits a JSON report. With compatible `coremltools` and `numpy` installed on macOS:

```sh
python Export/verify_cefrt2_coreml.py --delivery-dir . --backend coreml --report /tmp/cefrt2-coreml-cpu.json
```

Use `--backend static` for package inspection without Apple runtime, or `--backend torchscript` with PyTorch installed. Neither is a Core ML prediction test. Running the supplied tests never reads any evaluation images. Keep generated runtime reports outside this immutable delivery directory.

## Contents

- `Models/`: three packages and conversion audit JSON files.
- `TorchScript/`: frozen FP32 conversion inputs.
- `Fixtures/`: six synthetic test cases, full little-endian Float32 tensors and SHA-256 manifest.
- `Validation/`: independent graph/interface audit and actual Linux TorchScript results.
- `Export/`: trace, conversion, verification and packaging source; conversion can be repeated from the included TorchScript without original checkpoints.
- `Reference/`: byte-for-byte frozen Python geometry/preprocessing sources and provenance. These are integration references, not a standalone re-training application.
- `Licenses/`: original upstream RT-DETR and EdgeSAM notices.
- `delivery_manifest.json`, `SHA256SUMS.txt`: inventory and per-file integrity hashes.

## Reproduction And Integrity

The converter used Python 3.8.10, coremltools 7.2, torch 2.1.2+cpu and numpy 1.24.4 in WSL Ubuntu. Windows TorchScript tracing used torch 2.12.0+cu130 on CPU. Exact checkpoints and trace fingerprints are in `torchscript_manifest.json`; conversion fingerprints are in `coreml_manifest.json`.

To regenerate packages into a separate copy of the delivery directory:

```sh
python Export/convert_cefrt2_coreml_fp32.py --delivery-dir /path/to/delivery-copy
```

Tracing from original checkpoints additionally requires the original cheki repository/environment and the frozen checkpoint paths; those checkpoints are intentionally not duplicated here. The trace script imports production audit helpers from that repository.

Per-file hashes can be checked after extraction using `shasum -a 256 -c SHA256SUMS.txt`. Model directory hashes use sorted relative UTF-8 file names, each prefixed by its 8-byte little-endian length, followed by the corresponding file bytes. The inventory/checksum files are excluded from their own recursive inventories as documented in `delivery_manifest.json`.

## Upstream Notices

RT-DETR's bundled notice is Apache-2.0. EdgeSAM's bundled notice is **S-Lab License 1.0**, whose grant is for non-commercial use and directs commercial users to contact its contributors. This package includes the original notice and does not grant additional commercial rights. See `Licenses/EdgeSAM-LICENSE` before commercial distribution.
