# Numerical Validation Report

## Source Identity

| Frozen checkpoint | SHA-256 |
| --- | --- |
| RT-DETR epoch 24 | `65c90302a1064742b0befb67478ab58088b4973272380f9d4fbd43099b2df9c0` |
| EdgeSAM epoch 10 | `841c35089c4b49cf4beb2b3cd09df62af60c09378a490c66bcda05bb11f4d221` |

The official RT-DETR source commit is `068dfde65f2667ad6555883c69d73de886518cad`. Named invalid anchor slots retain the official positive-infinity sentinel and boolean mask; no blanket finite-value repair is performed. Source checkpoint files were not modified. EdgeSAM epoch 15 was not selected for export.

## Measurements Actually Performed

Two deterministic synthetic cases per component (seed 20260903), including zero and seeded noise inputs. No development or consumed-test image was read for export/validation. References are full output tensors from Windows eager FP32, not sampled elements.

Maximum absolute differences across both fixtures:

| Output | Windows saved/reloaded TorchScript vs eager | Linux torch 2.1.2 TorchScript vs Windows eager |
| --- | ---: | ---: |
| Detector logits | 1.64032e-4 | 2.02656e-4 |
| Detector normalized cxcywh | 7.71880e-6 | 2.34842e-5 |
| Encoder embeddings | 4.17233e-7 | 5.57303e-6 |
| Decoder mask logits | 0 | 9.53674e-6 |
| Decoder quality | 0 | 1.19209e-7 |

Each element passed the predeclared synthetic diagnostic criterion `abs(error) <= 1e-3 + 1e-4*abs(reference)`. These are smoke/parity diagnostics, not new image-level gate tolerances. Full measured errors, failed-element counts and package interface/type checks are in `Validation/linux_torchscript_verification.json`.

The internal bicubic lowering was separately probed: max absolute error **7.15256e-7**. Coefficients were derived using the original PyTorch bicubic operation on basis tensors; align_corners=False and original dimensions are preserved. FP32 operation ordering may differ, so this is not a bitwise-equivalence claim. Native fused MHA fastpath was disabled for tracing to express the same attention math through supported operators.

## Actual Core ML Export Inspection

All three packages converted with coremltools 7.2, saved, and reopened. Tensor names, input and output shapes, Float32 I/O, package-tree hashes and every serialized MIL tensor type were independently checked. No Float16/Float64 neural tensor types or custom/control-flow/NMS operators were found. Integer index and shape/control tensors remain integer types. Decoder conversion lowered small index constants from int64 to int32; this is not a floating-precision conversion.

## Not Tested

Core ML model compilation and execution are unavailable on this Windows/WSL host (`libcoremlpython` is absent on Linux). Therefore Core ML numerical parity is **unverified**, not passed. The included Python Mac verifier and Swift XCTest harness provide the actual next test; neither has been executed on Apple hardware here.

Swift source compilation, image preprocessing equivalence, G portability, complete image-to-quad Core ML equivalence, memory, latency, GPU and ANE behavior are also unverified. A successful synthetic CPU tensor test alone must not be reported as full iPhone readiness.

This export does not replace or improve the previously frozen Python evaluation results. Production training-set sanity and previously consumed-test metrics are not independent evidence about the new Core ML runtime. No retraining, threshold re-selection, consumed-test rerun, NMS, precision reduction or fallback was performed for this delivery.
