# Frozen Integration Contract

## Model Interfaces

All tensors are NCHW (where applicable), batch 1, Float32. The `.mlpackage` interfaces are tensor inputs, not Core ML image inputs with implicit normalization.

| Component | Input | Output |
| --- | --- | --- |
| Detector | `image [1,3,768,768]` | `logits [1,300]`, `boxes_cxcywh [1,300,4]` |
| Encoder | `image [1,3,1024,1024]` | `image_embeddings [1,256,64,64]` |
| BoxDecoder | `image_embeddings [1,256,64,64]`, `box [1,4]` | `mask_logits [1,1,256,256]`, `iou_prediction [1,1]` |

`logits` are raw foreground logits, not probabilities. `boxes_cxcywh` are normalized center-x, center-y, width, height in the detector letterbox. The decoder's `box` is XYXY in resized encoder pixel coordinates, not normalized coordinates. Its output is exactly mask token 0 (`num_multimask_outputs=1`), not the best of four masks.

`iou_prediction` is the decoder neural quality output. The original `SamPredictor.predict_torch` defaults to substituting a low-resolution stability score. These diagnostic scores are not identical; neither is used to select/reject masks in the frozen pipeline. Do not introduce a quality threshold.

## Detector Preparation And Restoration

1. Apply EXIF orientation, convert to RGB uint8. All final coordinates refer to this upright original image.
2. Let `scale=min(768/width,768/height)`. Resize to `max(1,round(width*scale))` by `max(1,round(height*scale))` using **OpenCV INTER_AREA**. Python `round` is ties-to-even.
3. Put that image in a zero-filled RGB uint8 768-square canvas with integer offsets `left=(768-resizedWidth)//2`, `top=(768-resizedHeight)//2`. Do not stretch the image or replace this resize with a generic bilinear filter.
4. Convert to FP32, divide by 255, subtract RGB means `[0.485,0.456,0.406]`, divide by `[0.229,0.224,0.225]`, transpose to NCHW. No additional Core ML normalization.
5. Apply FP32 sigmoid to all 300 logits. Keep each query with `score >= 0.9267578125`. Preserve its query ID. There is no new top-K, NMS, count cap or selector. The detector's own trained internal top-K remains in the graph.
6. In FP32, form XYXY as `center +/- extent*0.5`. Restore original coordinates as `(normalized_xyxy*768-[left,top,left,top])/Float32(scale)`. Do **not** clip boxes to image boundaries. Invalid/nonfinite outputs must raise an integration error, not be silently repaired.

## Square20 And Encoder Preparation

1. For each retained original-coordinate XYXY box, compute FP32 center and `side=max(width,height,2.0)*1.4`. ROI is `center +/- side*0.5`. The name square20 means a 20% margin on each side, not a 1.2 multiplier.
2. Crop pixel dimension is `max(64,round(Float64(roi_width)))`. Construct FP32 homography with `sx=(cropSide-1)/roi_width`, `sy=(cropSide-1)/roi_height`, translations `-sx*x1`, `-sy*y1`.
3. Convert upright RGB source pixels to FP32. Apply `cv2.warpPerspective` with `INTER_LINEAR`, constant border RGB `(123.675,116.28,103.53)`. Do not clip the ROI or quantize the crop back to uint8.
4. Resize each FP32 RGB channel independently to 1024-square using **Pillow F-mode BILINEAR**. This preserves fractional pixels; uint8 RGB resizing is not equivalent.
5. Subtract RGB means `[123.675,116.28,103.53]` and divide by `[58.395,57.12,57.375]` in FP32; convert to NCHW. Encoder input is already normalized. Square crops need no further bottom/right padding.
6. Transform the four original AABB corners using the FP32 homography. Take coordinate-wise min/max to form crop XYXY, then multiply by `1024/Float32(cropSide)` to obtain the decoder `box` input. The PromptEncoder inside the model applies its original half-pixel convention; the caller must **not** add another 0.5.

## Mask And Frozen G

1. Decode with the single box and encoder embedding. Point prompts and mask-input prompts are absent.
2. Upsample raw mask logits from 256-square to 1024-square using FP32 PyTorch bilinear semantics, `align_corners=False`.
3. Remove encoder padding according to resized input size (1024-square for this pipeline), then separately resize to cropSide-square using the same bilinear semantics. Do not fuse the two resizes.
4. Create the binary mask with **logit > 0.0**, not `>=0`, not sigmoid/threshold resizing, and not a threshold on the low-resolution tensor.
5. Call frozen `mask_to_quad_ransac(mask)` with default `filter_dist=80`, `inlier_dist=5`; apply frozen `order_quad`. The included `Reference/ransac_quadrilateral.py` is the exact source of G.
6. Convert the forward homography to FP64, invert it, transform the crop quad back to original coordinates in FP64, and order TL/TR/BR/BL. The production serialization rounds coordinates to six decimals.
7. On a fit failure, retain an explicit error/no valid quad. Do not synthesize a rectangle, use the detector box as a final quad, or add a fallback. Do not add final QNMS. Handle a zero-query image as an empty prediction set.

The FP32 requirement applies to neural weights, activations, I/O and specified image/forward-coordinate operations. Frozen G and inverse geometry deliberately use FP64; changing them to FP32 is not authorized by this export.

## Differences From The Early v1 Core ML Package

- Three new interfaces replace the earlier FPN/RPN, ROI heads, selector, encoder and generic prompt-decoder arrangement. Do not connect v2 to old detector/selector code.
- This delivery is FP32 throughout its neural graphs, not the early FP16 export settings.
- Original EdgeSAM bicubic upsampling is retained mathematically using fixed-size separable matrices; it is **not replaced by bilinear**. Only the fixed 32-to-64 internal encoder upsample is lowered. Host RGB and mask resizes retain their separate original filters.
- Box prompts use the actual original PromptEncoder box path, including box-specific embeddings. Old generic point-coordinate/point-label adapters are not a substitute.
- No Swift/OpenCV/Pillow/G numerical equivalence is claimed by supplying reference sources. Validate the application's complete image path separately before deployment.

## Runtime Policy

Start validation with CPU-only Core ML, as supplied in the adapter/tests. The package's stored FP32 graph does not prove a particular device backend uses bit-identical math or preserves precision internally. GPU/ANE performance and numerical acceptance remain untested and must not be inferred from this export. The public adapter does not change thresholds, sort/filter outputs, run NMS, resize images or replace G.
