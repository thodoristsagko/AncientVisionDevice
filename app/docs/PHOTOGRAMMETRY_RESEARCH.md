# Photogrammetry Research & Implementation Analysis

## AncientVision Archaeological App

**Date:** February 2026
**Version:** 2.0 (Comprehensive State-of-the-Art Survey)
**Purpose:** Exhaustive analysis of cutting-edge photogrammetry techniques, 3D reconstruction methods, and their applicability to the AncientVision FLL archaeological documentation platform.

---

## Table of Contents

1. [Existing Codebase Analysis](#1-existing-codebase-analysis)
2. [Feature Detection & Matching (SOTA 2024-2026)](#2-feature-detection--matching-sota-2024-2026)
3. [3D Gaussian Splatting](#3-3d-gaussian-splatting)
4. [Neural Radiance Fields (NeRF)](#4-neural-radiance-fields-nerf)
5. [Structure from Motion (Modern SfM)](#5-structure-from-motion-modern-sfm)
6. [Multi-View Stereo (Dense Reconstruction)](#6-multi-view-stereo-dense-reconstruction)
7. [Surface Reconstruction from Point Clouds](#7-surface-reconstruction-from-point-clouds)
8. [Archaeological & Cultural Heritage Specific](#8-archaeological--cultural-heritage-specific)
9. [Real-Time & Mobile Photogrammetry](#9-real-time--mobile-photogrammetry)
10. [AI-Enhanced Photogrammetry](#10-ai-enhanced-photogrammetry)
11. [Bundle Adjustment & Optimization](#11-bundle-adjustment--optimization)
12. [Quality Metrics & Validation](#12-quality-metrics--validation)
13. [File Formats & Interoperability](#13-file-formats--interoperability)
14. [Comparison Matrix](#14-comparison-matrix)
15. [Implementation Roadmap](#15-implementation-roadmap)
16. [Sources](#16-sources)

---

## 1. Existing Codebase Analysis

AncientVision contains **5,600+ lines** of photogrammetry code across **13 files**. The system implements a complete hybrid pipeline: on-device sparse SfM preview + cloud-based dense reconstruction via OpenScan Cloud.

### File Inventory

| File | Lines | Category |
|------|-------|----------|
| `lib/services/reconstruction_service.dart` | 1,823 | Core SfM engine |
| `lib/screens/photogrammetry_screen.dart` | 2,735 | Capture UI + workflow |
| `lib/widgets/photogrammetry_capture_overlay.dart` | 964 | Capture guidance UI |
| `lib/widgets/measurement_tools_3d.dart` | 782 | 3D measurement tools |
| `lib/services/cloud_photogrammetry_service.dart` | 580 | OpenScan Cloud API |
| `lib/services/multi_cloud_photogrammetry.dart` | 420 | Multi-provider failover |
| `lib/widgets/model_3d_viewer.dart` | 418 | 3D model viewer |
| `lib/services/sfm_robust.dart` | 399 | RANSAC + Essential Matrix |
| `scripts/photogrammetry_process.py` | 359 | Desktop Meshroom CLI |
| `lib/widgets/point_cloud_painter.dart` | 298 | Point cloud renderer |
| `lib/models/mesh_model.dart` | 269 | Mesh data model |
| `lib/models/reconstruction_result.dart` | 224 | Result container |
| `lib/models/point_cloud.dart` | 205 | Point cloud model |

**Total: ~9,476 lines** (including photogrammetry_screen.dart extraction)

### Current Pipeline (10 Steps)

| Step | Progress | Operation | Details |
|------|----------|-----------|---------|
| 1 | 5-15% | Image loading & downsampling | Resize to 1024x1024, memory-managed |
| 2 | 15-45% | Feature extraction | Multi-scale Harris corner detector (3 scales: 1.0, 0.75, 0.5) |
| 3 | 45-65% | Feature matching | Cross-checked Lowe's ratio test (0.75 threshold) |
| 4 | 65-70% | Camera pose estimation | RANSAC + Essential Matrix (via `sfm_robust.dart`) |
| 5 | 70-80% | Point triangulation | Ray-pair intersection with 3 quality checks |
| 6 | 80-85% | Bundle adjustment | 10-iteration gradient descent optimization |
| 7 | 85-88% | Outlier removal | k-NN statistical outlier filtering (k=10, 2.0 std) |
| 8 | 88-92% | Multi-view color sampling | Weighted average from visible cameras |
| 9 | 92-96% | Normal estimation | Covariance-based local neighborhood normals |
| 10 | 96-100% | Point interpolation | Midpoint insertion between nearby points (max 500) |

### Current Limitations

- Simplified SVD (power iteration on A^T*A, not true SVD decomposition)
- Essential Matrix constraint enforcement is approximate (scaling, not U*diag(1,1,0)*V^T)
- Pose recovery uses fixed rotation approximations rather than proper SVD decomposition
- Bundle adjustment uses simple numerical gradient descent (not Levenberg-Marquardt)
- O(n^2) nearest-neighbor search for outlier removal and normal estimation
- Harris corners are less robust than SIFT/ORB/SuperPoint for feature matching

---

## 2. Feature Detection & Matching (SOTA 2024-2026)

### 2.1 SuperPoint (Self-Supervised Keypoints)

- **Paper**: DeTone, Rabinovich, Tomczak. "SuperPoint: Self-Supervised Interest Point Detection and Description." CVPRW 2018.
- **Architecture**: Fully convolutional encoder-decoder. Shared VGG-style encoder, two decoder heads (keypoint + descriptor). 65-channel keypoint head over 8x8 grid cells, 256-dim descriptors.
- **Strengths**: Robust to illumination changes, viewpoint variation, and motion blur. Trained via homographic adaptation on MS-COCO.
- **Mobile**: ONNX export available; ~1M parameters. Feasible on mobile with ONNX Runtime or TFLite conversion.
- **GitHub**: [magicleap/SuperPointPretrainedNetwork](https://github.com/magicleap/SuperPointPretrainedNetwork)

### 2.2 SuperGlue (Graph Neural Network Matching)

- **Paper**: Sarlin, DeTone, Malisiewicz, Rabinovich. "SuperGlue: Learning Feature Matching with Graph Neural Networks." CVPR 2020.
- **Architecture**: Attentional Graph Neural Network with self-attention and cross-attention layers, followed by a differentiable Sinkhorn optimal transport layer for assignment.
- **Performance**: State-of-the-art matching accuracy but computationally heavy (~12M params).
- **Mobile**: Difficult due to attention mechanism complexity. Superseded by LightGlue.

### 2.3 LightGlue (Recommended for Mobile)

- **Paper**: Lindenberger, Sarlin, Pollefeys. "LightGlue: Local Feature Matching at Light Speed." ICCV 2023.
- **Architecture**: Adaptive transformer with early stopping -- skips unnecessary computation for easy image pairs. Bidirectional cross-attention shares similarity matrices for 2x speedup over SuperGlue. Adaptive depth: easy pairs use fewer layers.
- **Performance**: **150 FPS @ 1024 keypoints, 50 FPS @ 4096 keypoints** -- a 4-10x speedup over SuperGlue with equal or better accuracy.
- **Mobile**: Yes, via ONNX Runtime. Has been integrated into SLAM systems (Light-SLAM). Available on [HuggingFace](https://huggingface.co/ETH-CVG/lightglue_superpoint).
- **GitHub**: [cvg/LightGlue](https://github.com/cvg/LightGlue)
- **Archaeological relevance**: Excellent for matching weathered stone textures, inscriptions with significant viewpoint changes.

### 2.4 LoFTR (Detector-Free Dense Matching)

- **Paper**: Sun, Shen, et al. "LoFTR: Detector-Free Local Feature Matching with Transformers." CVPR 2021 / T-PAMI 2022.
- **Architecture**: Coarse-level matching via self+cross attention on 1/8 resolution feature maps, then fine-level sub-pixel refinement. No keypoint detection step -- matches are produced directly from dense feature correlation.
- **Strength**: Excels in **low-texture regions** where keypoint detectors fail (critical for worn archaeological surfaces, uniform stone, sandy terrain).
- **Mobile**: Too heavy due to transformer attention on dense features. Cloud processing only.
- **GitHub**: [zju3dv/LoFTR](https://github.com/zju3dv/LoFTR)

### 2.5 RoMa (Current SOTA Dense Matcher, CVPR 2024)

- **Paper**: Edstedt, Sun, Bokman. "RoMa: Robust Dense Feature Matching." CVPR 2024.
- **Architecture**: Frozen **DINOv2** foundation model backbone + specialized ConvNet + Transformer decoder. Produces pixel-dense warps with per-pixel certainty estimates.
- **Performance**: 36% improvement on WxBS (extreme viewpoint changes). State-of-the-art on MegaDepth, ScanNet, InLoc benchmarks.
- **Mobile**: Not suitable (DINOv2 backbone is too large).
- **GitHub**: [Parskatt/RoMa](https://github.com/Parskatt/RoMa)
- **Archaeological relevance**: Best for matching across extreme lighting/viewpoint conditions in field work, excavation trenches with shadows.

### 2.6 DISK (Policy Gradient Keypoints)

- **Paper**: Tyszkiewicz, Fua, Lepetit. "DISK: Learning local features with policy gradient." NeurIPS 2020.
- **Architecture**: U-Net-based keypoint detector + descriptor trained with reinforcement learning. Per-match reward signal rather than global reward.
- **GitHub**: [cvlab-epfl/disk](https://github.com/cvlab-epfl/disk)

### 2.7 ALIKED (Lightweight Learned Features)

- **Paper**: Zhao et al. "ALIKED: A Lighter Keypoint and Descriptor Extraction Network via Deformable Transformation." IEEE T-IM 2023.
- **Architecture**: Deformable convolutions for adaptive receptive fields. Significantly lighter than SuperPoint while maintaining competitive accuracy.
- **Mobile**: Most promising learned detector for on-device mobile deployment due to lightweight architecture.

### 2.8 Comparison Matrix

| Method | Type | Speed | Mobile? | Low-Texture | Accuracy | Params |
|--------|------|-------|---------|-------------|----------|--------|
| Harris/ORB | Classical detect+match | Very fast | Yes | Poor | Moderate | 0 |
| SIFT | Classical detect+match | Moderate | Yes (OpenCV) | Moderate | Good | 0 |
| SuperPoint+LightGlue | Learned detect+match | 150 FPS | Yes (ONNX) | Good | Very Good | ~2M |
| ALIKED+LightGlue | Learned detect+match | Fast | Yes | Good | Very Good | ~1M |
| LoFTR | Detector-free dense | Slow | No | Excellent | Very Good | ~12M |
| RoMa | Dense warp | Slow | No | Excellent | SOTA | ~300M |
| DUSt3R/MASt3R | Pointmap regression | Moderate | No | Excellent | SOTA | ~300M |

**Recommendation for AncientVision**: Use **SuperPoint+LightGlue** as the on-device pipeline (ONNX Runtime on Android). For cloud processing, use **RoMa** or **MASt3R** for highest quality on challenging archaeological surfaces.

---

## 3. 3D Gaussian Splatting

### 3.1 Original 3DGS (SIGGRAPH 2023)

- **Paper**: Kerbl, Kopanas, Leimkuhler, Drettakis. "3D Gaussian Splatting for Real-Time Radiance Field Rendering." SIGGRAPH 2023.
- **Representation**: Scene is a collection of 3D Gaussian primitives, each parameterized by:
  - **Position**: mean μ ∈ ℝ³
  - **Covariance**: 3×3 matrix, stored as scaling vector **s** and rotation quaternion **q**
  - **Opacity**: α ∈ [0,1]
  - **Color**: Spherical harmonics coefficients (up to degree 3, 48 coefficients for view-dependent color)
- **Rendering**: Differentiable tile-based rasterizer. Gaussians are projected to 2D screen space, sorted by depth per tile, alpha-composited front-to-back.
- **Training**: ~7 minutes for a scene (vs hours for NeRF). Requires SfM point cloud initialization (typically COLMAP).
- **Quality**: Comparable to Zip-NeRF at 100+ FPS rendering.
- **GitHub**: [graphdeco-inria/gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting)

### 3.2 Mathematical Formulation

A 3D Gaussian is defined by:

```
G(x) = exp(-½ (x - μ)^T Σ^{-1} (x - μ))
```

Where Σ is decomposed as:

```
Σ = R S S^T R^T
```

With R as rotation matrix (from quaternion) and S as diagonal scaling matrix. This ensures positive semi-definiteness.

**2D Projection**: The 3D covariance is projected to 2D via:

```
Σ' = J W Σ W^T J^T
```

Where W is the viewing transformation and J is the Jacobian of the affine approximation of the projective transformation.

**Alpha compositing** (front-to-back):

```
C = Σ_i c_i α_i Π_{j=1}^{i-1} (1 - α_j)
```

### 3.3 Compression Methods (Critical for Mobile)

**LightGaussian** (NeurIPS 2024):
- Pipeline: Global saliency pruning → VecTree hybrid quantization → run-length encoding
- **15x compression**, rendering increases from 139 FPS to 215 FPS
- GitHub: [VITA-Group/LightGaussian](https://github.com/VITA-Group/LightGaussian)

**Compact-3DGS** (CVPR 2024):
- Uses neural field for view-dependent color, codebook-based vector quantization
- **25x+ storage reduction** while maintaining quality
- GitHub: [maincold2/Compact-3DGS](https://github.com/maincold2/Compact-3DGS)

**Mini-Splatting** (ECCV 2024):
- Constrains the number of Gaussians via importance-based densification and simplification
- Achieves near-original quality with far fewer primitives

**LFGS** (2025):
- Lightweight framework achieving **90x+ memory compression** while maintaining fidelity
- Specifically designed for mobile/VR deployment

### 3.4 2D Gaussian Splatting (2DGS) -- For Surface Reconstruction

- **Paper**: Huang et al. "2D Gaussian Splatting for Geometrically Accurate Radiance Fields." SIGGRAPH 2024.
- **Key Innovation**: Replaces 3D Gaussians with 2D oriented planar disks. This provides **view-consistent geometry** and enables direct mesh extraction via TSDF fusion (using Open3D).
- **Mesh Extraction**: Perspective-accurate ray-splat intersection + depth distortion loss + normal consistency loss.
- **Archaeological relevance**: Superior for extracting accurate geometric meshes from archaeological artifacts and structures where measurement accuracy matters.
- **GitHub**: [hbb1/2d-gaussian-splatting](https://github.com/hbb1/2d-gaussian-splatting)

### 3.5 Gaussian Splatting Editing

**GaussianEditor** (CVPR 2024):
- Edit 3DGS scenes using text prompts or segmentation masks
- Allows adding, removing, or modifying objects in reconstructed scenes

**GaussianDreamer** (CVPR 2024):
- Text-to-3D Gaussians. Uses 3D diffusion for initialization + 2D diffusion for enrichment.
- GitHub: [hustvl/GaussianDreamer](https://github.com/hustvl/GaussianDreamer)

### 3.6 Khronos KHR_gaussian_splatting glTF Extension

- **Status (Feb 2026)**: **Release candidate** published by Khronos Group on Feb 3, 2026.
- **Structure**: Stores Gaussians as point primitives in glTF 2.0 with attributes: position, rotation, scale, opacity, spherical harmonics (diffuse + specular). Graceful fallback to sparse point cloud rendering for non-supporting viewers.
- **Companion extension**: `KHR_gaussian_splatting_compression_spz` for efficient streaming using SPZ format.
- **Industry backing**: NVIDIA, Google, Adobe, Cesium all supporting.
- **Significance**: This is the standardization event that makes 3DGS a viable interchange format for cultural heritage archives.

### 3.7 Web/Mobile 3DGS Viewers

| Viewer | Technology | Features | GitHub |
|--------|-----------|----------|--------|
| antimatter15/splat | WebGL 1.0 | Zero dependencies, progressive loading, touch controls | [antimatter15/splat](https://github.com/antimatter15/splat) |
| gsplat.js | Three.js API | HuggingFace-backed, .ply/.splat support | [huggingface/gsplat.js](https://github.com/huggingface/gsplat.js) |
| GaussianSplats3D | Three.js | Full integration, multiple format support | [mkkellogg/GaussianSplats3D](https://github.com/mkkellogg/GaussianSplats3D) |

### 3.8 Archaeological Applications of 3DGS

Recent publications confirm 3DGS as transformative for heritage documentation:

- **Damaged statue visualization**: Nature Heritage Science (2025) -- 3DGS + web interfaces for damaged cultural heritage objects. DOI: 10.1038/s40494-025-02063-5
- **Super-resolution 3DGS**: Nature Heritage Science (2026) -- High-fidelity heritage reconstruction via progressive Gaussian splatting. DOI: 10.1038/s40494-026-02355-4
- **Architectural heritage**: UAV-based 3DGS for modern architectural heritage documentation (2025). GDMC Publication.
- **SIGGRAPH 2024**: "Beyond Digital Twins" -- 3DGS + game engines for cultural heritage.
- **Frontiers in Computer Science (2025)**: "Immersive heritage through Gaussian Splatting: a new visual aesthetic for reality capture."

**Training**: Currently requires NVIDIA GPU (CUDA). Cloud-only for training; mobile for viewing compressed results via WebGL.

---

## 4. Neural Radiance Fields (NeRF)

### 4.1 Instant-NGP (SIGGRAPH 2022)

- **Paper**: Muller, Evans, Schied, Keller. "Instant Neural Graphics Primitives with a Multiresolution Hash Encoding." SIGGRAPH 2022.
- **Key Innovation**: Multi-resolution hash grid encoding achieves **1000x speedup** over original NeRF. Training in seconds, rendering in milliseconds on GPU.
- **Hash Encoding**: Maps spatial coordinates to learnable feature vectors via a cascade of hash tables at different resolutions. Each level provides features at its resolution, concatenated and fed to a small MLP.
- **GitHub**: [NVlabs/instant-ngp](https://github.com/NVlabs/instant-ngp)

### 4.2 Zip-NeRF (ICCV 2023)

- **Paper**: Barron et al. "Zip-NeRF: Anti-Aliased Grid-Based Neural Radiance Fields." ICCV 2023.
- **Key**: Combines Mip-NeRF 360 quality with Instant-NGP speed. 8-76% error reduction over prior methods, 22x faster than Mip-NeRF 360. Currently the highest-quality NeRF variant.

### 4.3 Mesh Extraction from NeRFs

**BakedSDF** (SIGGRAPH 2023):
- Optimizes neural surface-volume hybrid, then "bakes" into high-resolution mesh for real-time rendering. Supports appearance editing and physics simulation.

**NeRF2Mesh** (ICCV 2023):
- Adaptive surface refinement: optimizes vertex positions and face density based on rendering errors.
- GitHub: [ashawkey/nerf2mesh](https://github.com/ashawkey/nerf2mesh)

**MobileNeRF** (CVPR 2023):
- Converts NeRF into textured polygon mesh renderable via standard GPU rasterization pipeline.
- Can run on mobile devices using standard OpenGL ES.

### 4.4 Neural Implicit Surfaces

**NeuS2** (ICCV 2023):
- **100x faster** than NeuralAngelo while maintaining quality. Full CUDA implementation with multi-resolution hash encodings and lightweight second-order derivatives for ReLU MLPs.

**NeuralAngelo** (NVIDIA, CVPR 2023):
- Higher smoothness and specular highlights but 100x slower than NeuS2. Best for highest-quality surface extraction where time is not a constraint.

### 4.5 NeRF vs 3DGS Comparison (2025-2026)

| Aspect | NeRF (Zip-NeRF) | 3DGS |
|--------|-----------------|------|
| Training speed | Minutes (Instant-NGP) | Minutes |
| Rendering speed | ~10 FPS (volumetric) | 100+ FPS (rasterization) |
| Visual quality | Highest (Zip-NeRF) | Near Zip-NeRF |
| Editability | Difficult (implicit) | Easy (explicit primitives) |
| Mesh extraction | BakedSDF/NeRF2Mesh | 2DGS/TSDF |
| Mobile rendering | MobileNeRF (baked mesh) | WebGL viewers |
| Storage | Compact (neural weights) | Large (but compressible 15-90x) |
| Standardization | None | glTF KHR_gaussian_splatting |

**Consensus 2025-2026**: 3DGS has won for real-time applications and interchange. NeRF remains valuable for highest-quality offline rendering. Hybrid approaches (using NeRF to assist 3DGS training) are emerging.

---

## 5. Structure from Motion (Modern SfM)

### 5.1 COLMAP (Baseline Reference)

- **Authors**: Schonberger, Frahm. "Structure-from-Motion Revisited." CVPR 2016.
- **Pipeline**: Feature extraction → Exhaustive/Spatial matching → Incremental SfM (register image → triangulate → bundle adjust → repeat).
- **Strengths**: Extremely robust, widely used, well-tested. Python bindings (PyCeres) available.
- **Limitation**: Incremental approach is slow for large image sets (O(n²) matching, sequential registration).
- **GitHub**: [colmap/colmap](https://github.com/colmap/colmap)

### 5.2 GLOMAP -- Global SfM (ECCV 2024)

- **Paper**: Pan et al. "Global Structure-from-Motion Revisited." ECCV 2024.
- **Key Innovation**: Global SfM estimates all camera poses simultaneously rather than incrementally. **Orders of magnitude faster** than COLMAP with equal or better accuracy.
- **Pipeline**: Takes COLMAP database as input, outputs COLMAP-format sparse reconstruction. Drop-in replacement for COLMAP's mapper.
- **Approach**: Rotation averaging → Translation averaging → Global bundle adjustment.
- **GitHub**: [colmap/glomap](https://github.com/colmap/glomap)
- **Archaeological relevance**: Enables processing large site surveys (thousands of images) that would be prohibitively slow with incremental SfM.

### 5.3 VGGT -- Visual Geometry Grounded Transformer (CVPR 2025 Best Paper)

- **Paper**: Wang, Chen et al. "VGGT: Visual Geometry Grounded Transformer." CVPR 2025 **Best Paper Award**.
- **Architecture**: 1.2B parameter transformer with L=24 layers. Alternating local and global attention. Accepts 1 to hundreds of images.
- **Outputs in a single forward pass**: Camera parameters (intrinsics + extrinsics), point maps, depth maps, and 3D point tracks.
- **Performance**: ~0.2 seconds per scene. Outperforms all alternatives without post-processing.
- **Revolutionary aspect**: A single model replaces the entire SfM+MVS pipeline. No iterative optimization, no RANSAC, no bundle adjustment -- pure feed-forward inference.
- **GitHub**: [facebookresearch/vggt](https://github.com/facebookresearch/vggt)
- **Mobile**: No (1.2B params). Cloud processing only.
- **Archaeological relevance**: Rapid site documentation. Upload photos, get full 3D reconstruction in <1 second on GPU server.

### 5.4 SwiftVGGT (2025)

- Extends VGGT to handle large-scale scenes more efficiently.
- Overcomes VGGT's memory limitations for very large image collections.

### 5.5 DUSt3R / MASt3R (Naver Labs, 2024)

**DUSt3R** (CVPR 2024):
- "Geometric 3D Vision Made Easy."
- Vision transformer that regresses **pointmaps** (per-pixel 3D coordinates) directly from image pairs. No camera model assumptions needed.

**MASt3R** (ECCV 2024):
- Extends DUSt3R with pixel correspondence prediction and local features.
- **Outperforms LoFTR and SuperGlue** on matching benchmarks while simultaneously producing 3D reconstruction.
- **MASt3R-SfM**: Full SfM pipeline built on MASt3R. Handles unconstrained image collections.
- **MASt3R-SLAM**: Real-time dense SLAM. Outperforms ORB-SLAM3 and DROID-SLAM on geometry consistency.

### 5.6 Regist3R (ACM MM 2025)

- Incremental registration using stereo foundation model (builds on DUSt3R/MASt3R family).
- Minimum spanning tree inference strategy for efficient large-scale reconstruction.
- First to reconstruct **1000+ view scenes** using pointmap foundation models.
- **GitHub**: [Liu-SD/Regist3R](https://github.com/Liu-SD/Regist3R)

### 5.7 ACE0 -- Scene Coordinate Reconstruction (ECCV 2024 Oral)

- **Paper**: Brachmann et al. (Niantic). "Scene Coordinate Reconstruction: Posing of Image Collections via Incremental Learning of a Relocalizer."
- **Approach**: Re-interprets incremental SfM as iterated visual relocalization. Learns an implicit neural scene representation.
- **Advantage**: No pose priors or sequential input needed. Scales efficiently over thousands of images.
- **GitHub**: [nianticlabs/acezero](https://github.com/nianticlabs/acezero)

### 5.8 FlowMap (3DV 2025)

- **Paper**: Smith, Charatan, Tewari, Sitzmann. "FlowMap: High-Quality Camera Poses, Intrinsics, and Depth via Gradient Descent."
- **Approach**: End-to-end differentiable. Minimizes least-squares error between predicted optical flow and flow induced by depth+pose. Recovers camera poses, intrinsics, AND per-frame dense depth.
- **GitHub**: [dcharatan/flowmap](https://github.com/dcharatan/flowmap)

### 5.9 PoseDiffusion (ICCV 2023)

- **Paper**: Wang, Rupprecht, Novotny. "PoseDiffusion: Solving Pose Estimation via Diffusion-aided Bundle Adjustment."
- **Approach**: Formulates SfM inside a probabilistic diffusion framework. Reverse diffusion guided by Sampson Epipolar Error for geometric consistency.
- **GitHub**: [facebookresearch/PoseDiffusion](https://github.com/facebookresearch/PoseDiffusion)

### 5.10 Pixel-Perfect SfM (ICCV 2021, Best Student Paper)

- **Paper**: Lindenberger, Sarlin, Larsson, Pollefeys.
- **Key**: Refines keypoint locations and camera poses using direct alignment of deep features. Optimizes a **featuremetric error** based on dense CNN features.
- **Integrates with COLMAP** as a post-processing step for sub-pixel accuracy.
- **GitHub**: [cvg/pixel-perfect-sfm](https://github.com/cvg/pixel-perfect-sfm)

---

## 6. Multi-View Stereo (Dense Reconstruction)

### 6.1 PatchMatchNet (CVPR 2021 Oral)

- **Paper**: Wang, Galliani et al. "PatchmatchNet: Learned Multi-View Patchmatch Stereo."
- **Architecture**: Cascade formulation of learned PatchMatch. Coarse-to-fine multi-scale cost volume with adaptive propagation and evaluation.
- **Key advantage**: Significantly lower memory consumption than 3D CNN approaches, enabling higher-resolution processing.
- **GitHub**: [FangjinhuaWang/PatchmatchNet](https://github.com/FangjinhuaWang/PatchmatchNet)

### 6.2 CasMVSNet (Cascade Cost Volume)

- Processes images at raw resolution through coarse-to-fine cascade architecture on feature pyramid network (FPN).
- Memory-efficient via cascade: each stage narrows the depth hypothesis range.

### 6.3 SimpleRecon (Niantic, ECCV 2022)

- **Key**: High-quality multi-view depth prediction leading to accurate 3D reconstruction using off-the-shelf depth fusion. Injects camera metadata directly into feature volumes.
- **Advantage**: **Real-time, low-memory online reconstruction** from video streams.
- **GitHub**: [nianticlabs/simplerecon](https://github.com/nianticlabs/simplerecon)

### 6.4 Integration with SfM

Standard dense reconstruction pipeline:
```
SfM (sparse points + camera poses)
  → MVS (dense depth maps per image)
  → Depth fusion (TSDF or point cloud merging)
  → Surface reconstruction (Poisson/BPA)
```

COLMAP includes a built-in PatchMatch MVS stage. Modern approaches like VGGT and DUSt3R bypass this entirely by producing dense reconstruction directly from the transformer forward pass.

---

## 7. Surface Reconstruction from Point Clouds

### 7.1 Screened Poisson Surface Reconstruction (SIGGRAPH 2013)

- **Paper**: Kazhdan, Hoppe. "Screened Poisson Surface Reconstruction." SIGGRAPH 2013.
- **Algorithm**: Solves a Poisson equation with screening term. The indicator function χ satisfies:
  ```
  ∇χ = V   (V = oriented normal field)
  ```
  With screening: minimize `||∇χ - V||² + α||χ||²` where α controls interpolation vs. approximation.
- **Requirements**: Oriented normals for each point.
- **Output**: Watertight mesh. The density return value is critical for identifying poorly-supported regions and removing reconstruction artifacts.
- **Open3D**: `create_from_point_cloud_poisson()` with density-based filtering.
- **Archaeological relevance**: Standard for mesh generation from dense point clouds. Best quality for complete objects.

### 7.2 Ball Pivoting Algorithm (BPA)

- **Open3D**: `create_from_point_cloud_ball_pivoting()` with multiple radii.
- **Advantage**: Does not fill holes, preserving actual data boundaries. Better for incomplete archaeological objects where you want to show only what was actually measured, not interpolated geometry.

### 7.3 Alpha Shapes

- **Open3D**: `create_from_point_cloud_alpha_shape()`. Based on Delaunay triangulation filtered by alpha radius.
- **Use case**: Quick visualization, hull computation. Not suitable for high-quality reconstruction.

### 7.4 Neural Implicit Surface Reconstruction

**NeuralAngelo** (NVIDIA, CVPR 2023):
- Multi-resolution hash grids + numerical gradient computation for smooth surfaces.
- Best quality for large-scale scenes but very slow (hours).

**NeuS2** (ICCV 2023):
- 100x faster than NeuralAngelo. Full CUDA implementation.
- Suitable for heritage artifact reconstruction at server-side.

### 7.5 Open3D vs PCL

| Feature | Open3D (v0.19.0) | PCL |
|---------|-----------|-----|
| Language | Python-first (C++ core) | C++ (Python bindings available) |
| API | Modern, clean | Mature, more complex |
| Algorithms | Poisson, BPA, Alpha, TSDF | RANSAC, region growing, Euclidean clustering, PCL-specific algorithms |
| Tensor ops | Yes (Open3D tensor) | No |
| Best for | Cloud processing, prototyping | Embedded/real-time C++ applications |

**Recommendation**: Use Open3D for cloud processing pipeline; PCL concepts for any on-device C++ processing via FFI.

---

## 8. Archaeological & Cultural Heritage Specific

### 8.1 Multi-Scale Documentation Framework

Standard three-tier archaeological documentation approach:

| Level | Method | GSD | Use Case |
|-------|--------|-----|----------|
| Site (macro) | UAV/drone photogrammetry | 1-2.5 cm/px | Overall site layout, topography |
| Trench/structure (meso) | Terrestrial photogrammetry | 0.5-1 mm/px | Wall sections, floor plans, stratigraphy |
| Artifact (micro) | Close-range/turntable | <0.1 mm/px | Individual finds, inscriptions, tool marks |

### 8.2 Ground Control Points (GCPs)

- **Minimum**: 5 GCPs for aerial survey, distributed around site perimeter + center
- **Target accuracy**: GCP RMSE < 3.5 cm for typical archaeological survey
- **Best practice**: Use coded targets (e.g., Agisoft 12-bit, photogrammetric ring targets) for automatic detection
- **GCP-free alternative**: RTK GNSS positioning on drone for direct georeferencing (±2 cm accuracy)
- **Recent research (2025)**: GCP reliability and distribution effects on accuracy. DOI: 10.1080/10095020.2025.2451204

### 8.3 Color Calibration for Archaeological Documentation

- **ColorChecker Passport**: Capture in each lighting condition at start and end of session
- **Process**:
  1. Convert to Lab color space
  2. Compute ΔE between measured and reference patches
  3. Learn affine regression matrix (3×4, includes offset)
  4. Apply correction to all images before processing
- **Critical for**: Temporal comparison of deterioration, true color recording of painted surfaces, comparison of ceramics across sites

### 8.4 RTI (Reflectance Transformation Imaging)

- Captures surface microdetail through varying lighting angles (typically 40-100 light positions per capture)
- **Applications**: Submillimeter diagnostic detail from inscriptions, tool marks, wear patterns
- **Underwater RTI**: Adapted for subaquatic environments using scuba-deployable hardware
- **Integration**: RTI coefficients can be mapped as texture onto photogrammetric 3D models for combined geometric + surface detail documentation

### 8.5 Underwater Archaeological Photogrammetry

- **CRAB system (2025)**: Calibrated Rig for Aquatic photogrammetric Bicamera -- stereoscopic imaging with dome ports and optical calibration to minimize refractive distortion
- **Color correction**: Essential due to selective absorption of red/orange wavelengths by water (deeper = bluer)
- **Scale**: Underwater targets and scale bars must be visible in photos (metal rulers, calibrated frames)
- **Turbidity**: Limits visibility; close-range capture (50-100 cm) preferred

### 8.6 Metadata Standards

**Dublin Core**: Basic metadata elements (title, creator, date, coverage, description, format)

**CIDOC-CRM** (ISO 21127):
- Comprehensive ontology for cultural heritage documentation
- XML/RDF implementation for interoperability with world heritage databases
- Covers events, actors, physical things, temporal entities, and their relationships
- Required for submissions to many national heritage databases

### 8.7 Temporal 3D Comparison for Damage Assessment

- **Cloud-to-Cloud (C2C) distance**: Hausdorff distance or mean distance between temporal scans
- Requires consistent coordinate system (permanent GCPs or registration markers)
- Detects: erosion, structural settlement, crack propagation, vandalism
- Software: CloudCompare (free), Open3D (programmatic)

### 8.8 Single-Image 3D for Artifacts

- **InstantMesh (TencentARC, 2024)**: Feed-forward mesh generation from single image. Pipeline: Single image → Zero123++ (multi-view diffusion) → Sparse-view large reconstruction model → Textured mesh.
- **Nature Heritage Science (2025)**: "Single-image 3D reconstruction of painted potteries using AI diffusion and feedforward models." DOI: 10.1038/s40494-025-02114-x
- **Use case**: Rapid 3D preview of artifacts from a single photograph before full photogrammetric capture

---

## 9. Real-Time & Mobile Photogrammetry

### 9.1 ARCore Raw Depth API (Android)

- Provides per-pixel depth for supported pixels using ML-based monocular depth estimation
- **Half the compute cost** of full Depth API
- Includes confidence image for per-pixel accuracy assessment
- **Accuracy**: ~cm-level (varies by device and conditions)
- **Use case**: Real-time 3D reconstruction and measurement on Android devices
- **Flutter integration**: Via `arcore_flutter_plugin` or platform channels

### 9.2 Apple Object Capture / RoomPlan (iOS Reference)

- **Object Capture**: LiDAR-enhanced photogrammetry. New 2025 algorithm significantly improves quality for low-texture objects.
- **RoomPlan**: LiDAR-based room scanning with furniture classification.
- **Note**: iOS-only. Not directly applicable to AncientVision (Android target) but useful as quality benchmark.

### 9.3 SLAM Systems

**ORB-SLAM3** (T-RO 2021):
- First system supporting Visual, Visual-Inertial, and Multi-Map SLAM with monocular/stereo/RGB-D + pinhole/fisheye lenses.
- GitHub: [UZ-SLAMLab/ORB_SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3)

**MASt3R-SLAM** (2025):
- Dense SLAM using MASt3R (Section 5.5) priors.
- **Outperforms ORB-SLAM3 and DROID-SLAM** on camera pose and geometry consistency across multiple benchmarks.
- Represents the state of the art in visual SLAM as of 2025.

### 9.4 TFLite Depth Estimation Models

| Model | Params | Type | Mobile? | Notes |
|-------|--------|------|---------|-------|
| **MiDaS v2.1** | ~100M | Relative depth | Yes (TFLite) | Proven mobile deployment, good for shape |
| **Depth Anything V2 Small** | 25M | Relative depth | Yes | Best quality/size ratio for mobile |
| **Depth Anything V2 Large** | 335M | Relative depth | No (cloud) | SOTA depth quality |
| **ZoeDepth** | ~100M | **Metric depth** | Partial | Absolute scale via adaptive metric binning |

**MiDaS**: GitHub: [isl-org/MiDaS](https://github.com/isl-org/MiDaS)
**Depth Anything V2**: Project page: [depth-anything-v2.github.io](https://depth-anything-v2.github.io/)

**ZoeDepth** is critical for photogrammetry because it provides metric (absolute) depth, enabling scale-aware reconstruction without known calibration objects.

### 9.5 Gaussian Splatting Mobile Viewing

- WebGL viewers (antimatter15/splat, gsplat.js) run in mobile browsers
- Compressed 3DGS (LightGaussian 15x, LFGS 90x) enables mobile download
- KHR_gaussian_splatting glTF extension enables integration with standard 3D pipeline
- Flutter integration via WebView + gsplat.js or platform-channel native OpenGL ES renderer

---

## 10. AI-Enhanced Photogrammetry

### 10.1 Depth Anything V2 (Foundation Model for Depth)

- **Paper**: Yang et al. "Depth Anything V2." 2024.
- **Training**: Three key practices: (1) synthetic training images, (2) scaled teacher model, (3) large-scale pseudo-labeled real images.
- **Model sizes**: 25M (Small) to 1.3B (Giant) parameters.
- **Use in photogrammetry**: Initialize SfM depth priors, fill depth gaps in sparse reconstructions, provide dense depth supervision for 3DGS/NeRF training.

### 10.2 InstantMesh (TencentARC, 2024)

- **Paper**: "InstantMesh: Efficient 3D Mesh Generation from a Single Image with Sparse-view Large Reconstruction Models."
- **Pipeline**: Single image → multi-view diffusion model (Zero123++) → sparse-view large reconstruction model → textured mesh.
- **Speed**: Feed-forward, near-instant inference on GPU.
- **Archaeological use**: Rapid 3D preview of artifacts from single photograph before committing to full photogrammetric capture workflow.
- **GitHub**: [TencentARC/InstantMesh](https://github.com/TencentARC/InstantMesh)

### 10.3 Wonder3D (CVPR 2024)

- **Paper**: Long et al. "Wonder3D: Single Image to 3D using Cross-Domain Diffusion."
- **Method**: Generates consistent multi-view normal maps + color images via cross-domain attention in diffusion model.
- **Reconstruction**: Novel normal fusion produces high-quality mesh in **2-3 minutes**.

### 10.4 DreamGaussian (2023)

- **Paper**: Tang et al. "DreamGaussian: Generative Gaussian Splatting for Efficient 3D Content Generation."
- **Method**: Image or text to 3D Gaussians in **~2 minutes**. Includes UV-space texture refinement stage.
- **GitHub**: [dreamgaussian/dreamgaussian](https://github.com/dreamgaussian/dreamgaussian)

### 10.5 Stable Point Aware 3D (Stability AI)

- Text/image to 3D with explicit point cloud output.
- Stable Diffusion backbone fine-tuned for 3D-aware generation.

---

## 11. Bundle Adjustment & Optimization

### 11.1 Library Comparison

| Library | Language | Strengths | Best For |
|---------|----------|-----------|----------|
| **Ceres Solver** | C++ | Largest community, automatic differentiation, handles gauge freedom, general-purpose | General BA, SLAM back-end |
| **g2o** | C++ | Optimized for graph-based optimization, efficient sparse solving | Visual SLAM, pose graphs |
| **GTSAM** | C++ | iSAM2 incremental solving, Shonan rotation averaging | Real-time SLAM, global SfM |

### 11.2 Levenberg-Marquardt (LM) Algorithm

The standard algorithm for bundle adjustment:

```
(J^T J + λ diag(J^T J)) δ = -J^T r
```

Where:
- J is the Jacobian of residuals w.r.t. parameters
- r is the residual vector (reprojection errors)
- λ is the damping parameter (interpolates between Gauss-Newton and gradient descent)
- δ is the parameter update

**Adaptation**: λ is decreased when the update reduces the cost (more Gauss-Newton), increased otherwise (more gradient descent). This makes LM both fast near the optimum and stable far from it.

**Contrast with current AncientVision**: The current code uses simple numerical gradient descent, which converges much slower and lacks the adaptive behavior of LM.

### 11.3 Robust Cost Functions

Critical for outlier-heavy archaeological data (mismatches, moving objects, vegetation):

| Function | Formula | Behavior | Use Case |
|----------|---------|----------|----------|
| **Huber** | `ρ(s) = s if s ≤ k, else k(2√(s/k)-1)` | L2 near 0, L1 for large residuals | General robustness |
| **Cauchy** | `ρ(s) = k² log(1 + s/k²)` | Heavy-tailed, gradual downweighting | Many outliers |
| **Tukey biweight** | `ρ(s) = k²/6(1-(1-s/k²)³) if s≤k², else k²/6` | Zero weight beyond threshold | Aggressive outlier rejection |

### 11.4 Rotation Averaging

- **Shonan Rotation Averaging**: Certifiably optimal rotation averaging via semidefinite relaxation. Now part of GTSAM 4.1.
- Used in global SfM (GLOMAP, Section 5.2) to estimate all camera rotations simultaneously before translation estimation.

### 11.5 Global vs Incremental BA

| Approach | Speed | Robustness | Used By |
|----------|-------|-----------|---------|
| **Incremental** | Slow (sequential) | Very robust | COLMAP |
| **Global** | Fast (parallel) | Can be fragile on poorly-connected graphs | GLOMAP |
| **Hybrid** | Medium | Best of both | OpenMVG (hybrid BA) |

---

## 12. Quality Metrics & Validation

### 12.1 Ground Sample Distance (GSD)

```
GSD = (sensor_pixel_size × flight_height) / focal_length
```

| Application | Typical GSD | Resolution |
|-------------|-----------|------------|
| UAV site survey | 1-2.5 cm/px | Overall layout |
| Terrestrial structure | 0.5-1 mm/px | Architectural detail |
| Artifact close-range | <0.1 mm/px | Surface texture, inscriptions |

### 12.2 Reprojection Error

```
e = ||π(P, X_3d) - x_2d||
```

Where π is the camera projection function, P is the camera matrix, X_3d is the 3D point, x_2d is the measured 2D keypoint.

| Threshold | Quality |
|-----------|---------|
| Mean < 0.5 px | Excellent calibration |
| Mean < 1.0 px | Good |
| 95th percentile < 2.0 px | Acceptable |
| Mean > 2.0 px | Poor (check calibration) |

### 12.3 Point Cloud Quality Metrics

| Metric | Archaeological Standard |
|--------|----------------------|
| **Point density** | 100-1000 pts/m² (site), 10000+ pts/m² (artifact) |
| **Completeness** | Percentage of expected surface covered |
| **Noise level** | Standard deviation of points from fitted surface |
| **Uniformity** | Coefficient of variation of local density |

### 12.4 Mesh Quality

| Metric | Target |
|--------|--------|
| **Triangle aspect ratio** | < 5:1 (equilateral = 1:1, degenerate → ∞) |
| **Normal consistency** | >95% of face normals agree with neighbors |
| **Manifold check** | No non-manifold edges or vertices |
| **Self-intersections** | Zero |

### 12.5 Accuracy Assessment Methods

- **Checkpoints**: Independent GCPs not used in processing, RMSE computed against known coordinates
- **Cross-validation**: Leave-one-out GCP removal, process, compare
- **Cloud-to-Cloud (C2C)**: Hausdorff or mean distance between temporal scans (for damage assessment and monitoring)
- **Reference comparison**: Compare against terrestrial laser scan (TLS) ground truth

### 12.6 Key Metrics for AncientVision to Display

1. Number of matched images / total images
2. Mean reprojection error (px)
3. Number of 3D points reconstructed
4. Average point density (pts/m²)
5. GSD (if camera parameters known)
6. Reconstruction completeness estimate
7. Processing time

---

## 13. File Formats & Interoperability

### 13.1 Point Cloud Formats

| Format | Standard | Features | Best For |
|--------|----------|----------|----------|
| **E57** (ASTM E2807) | ASTM | XML metadata + binary points, intensity, color, normals | Archival, interchange |
| **LAS/LAZ** | ASPRS | Coordinates as scaled integers, classification | LiDAR-compatible data |
| **PLY** (Stanford) | De facto | ASCII or binary, flexible properties | Research, Open3D |
| **PCD** | PCL | Point Cloud Library native format | PCL workflows |
| **CopC** | Open | Cloud Optimized Point Cloud (octree in LAZ) | Web streaming |

### 13.2 Mesh Formats

| Format | Features | Best For |
|--------|----------|----------|
| **glTF 2.0 / GLB** | Khronos standard, textures, PBR materials, KHR extensions | Mobile, web, interchange |
| **OBJ** (Wavefront) | Simple, universal support | Legacy software |
| **USD** (Pixar/Apple) | Composition, layering, variants | Apple ecosystem |

### 13.3 3D Gaussian Splatting Formats

| Format | Notes |
|--------|-------|
| **.ply** (with Gaussian attributes) | Original format, large files |
| **.splat** | Compressed binary, used by antimatter15/splat viewer |
| **.spz** | Khronos-backed compression format for streaming |
| **glTF + KHR_gaussian_splatting** | Standard (release candidate Feb 2026) |

### 13.4 Web Streaming Formats

| Format | Technology | Scale | GitHub |
|--------|-----------|-------|--------|
| **3D Tiles** (Cesium) | HTTP streaming | Entire cities/sites | [gocesiumtiler](https://github.com/mfbonfigli/gocesiumtiler) |
| **Potree** | Octree LOD | Billions of points in browser | [potree/potree](https://github.com/potree/potree) |

### 13.5 Recommended Format Pipeline for AncientVision

```
Capture (JPEG + EXIF metadata)
  → SfM (COLMAP/VGGT) → sparse PLY
  → MVS (PatchMatchNet) → dense PLY
  → Surface Reconstruction (Poisson) → OBJ/GLB mesh
  → Optional: 3DGS training → .splat/.ply → KHR_gaussian_splatting GLB
  → Web sharing: 3D Tiles / Potree
  → Archive: E57 (with full metadata + CIDOC-CRM)
```

---

## 14. Comparison Matrix

### 14.1 Reconstruction Approaches

| Approach | Cost | Quality | Speed | Offline | Flutter Ready | Android | Archaeological Fit |
|----------|------|---------|-------|---------|--------------|---------|-------------------|
| **On-device SfM (current)** | Free | Low-Med | 30-120s | Yes | Yes (exists) | Yes | Good |
| **Cloud SfM (OpenScan)** | Free | High | 5-15min | No | Yes (exists) | Yes | Excellent |
| **VGGT (cloud)** | Free* | Very High | <1s per scene | No | Needs integration | Yes (cloud) | Excellent |
| **MASt3R-SfM (cloud)** | Free* | Very High | Minutes | No | Needs integration | Yes (cloud) | Excellent |
| **3DGS (cloud train)** | Free* | Very High | ~7 min train | No** | WebGL viewer | Yes | Excellent |
| **NeRF (cloud)** | Free* | Highest | Hours | No | No | Cloud only | Excellent |
| **ARCore Depth** | Free | Medium | Real-time | Yes | Partial | Yes | Good |
| **Meshroom (Desktop)** | Free | Very High | 10-60min | Yes | No (Python) | No | Excellent |

\* Requires GPU server
\** Training requires cloud; rendering can be on-device

### 14.2 Feature Matchers

| Method | Archaeological Surfaces | Speed | Mobile | Open Source |
|--------|----------------------|-------|--------|-------------|
| Harris (current) | Poor | Fast | Yes | Yes |
| SuperPoint+LightGlue | Very Good | 150 FPS | Yes (ONNX) | Yes |
| LoFTR | Excellent | Slow | No | Yes |
| RoMa | SOTA | Slow | No | Yes |
| MASt3R | SOTA | Moderate | No | Yes |

---

## 15. Implementation Roadmap

### Phase 1: Immediate Improvements (On-Device)

| Improvement | Impact | Effort | Details |
|------------|--------|--------|---------|
| Replace Harris with SuperPoint+LightGlue | Much better matching | Medium | ONNX Runtime on Android via platform channel |
| Add Depth Anything V2 Small | Dense depth priors | Medium | 25M params via TFLite, initialize SfM depth |
| Integrate ARCore Raw Depth API | Real-time depth capture | Medium | `arcore_flutter_plugin` or platform channels |
| Add quality metrics display | User feedback | Low | Reprojection error, point count, GSD |
| Add EXIF focal length parsing | Better camera calibration | Low | Read from JPEG EXIF, compute intrinsics |

### Phase 2: Cloud Processing Pipeline

| Improvement | Impact | Effort | Details |
|------------|--------|--------|---------|
| VGGT cloud endpoint | <1s full reconstruction | High | Deploy VGGT on GPU server, REST API |
| GLOMAP as fast alternative | Handle large image sets | Medium | Drop-in COLMAP replacement |
| Screened Poisson (Open3D) | High-quality meshes | Medium | Cloud-side surface reconstruction |
| 2DGS training | Best visual output | High | Train on GPU, export compressed splats |
| GLB mesh export | Standard interchange | Low | Open3D → GLB via trimesh |

### Phase 3: Advanced Features

| Improvement | Impact | Effort | Details |
|------------|--------|--------|---------|
| 3DGS web viewer | Share reconstructions | Medium | gsplat.js in WebView or native renderer |
| InstantMesh integration | Single-image 3D preview | Medium | Cloud API for quick artifact preview |
| C2C temporal comparison | Damage monitoring | Medium | Open3D cloud-to-cloud distance |
| KHR_gaussian_splatting export | Standard archive format | Low | When glTF extension is ratified |
| CIDOC-CRM metadata | Heritage database interop | Low | XML/RDF export with reconstruction metadata |

### What to Keep vs Replace

| Component | Recommendation | Reason |
|-----------|---------------|--------|
| `reconstruction_service.dart` | **Keep + enhance** | On-device SfM works; replace Harris with SuperPoint |
| `sfm_robust.dart` | **Keep** | RANSAC pipeline is functional |
| `cloud_photogrammetry_service.dart` | **Keep + add VGGT** | OpenScan works; add VGGT as premium option |
| `multi_cloud_photogrammetry.dart` | **Keep** (add VGGT provider) | Multi-provider architecture supports new backends |
| All model files | **Keep** | Data models are clean and correct |
| All widget files | **Keep** | UI is polished and comprehensive |
| `photogrammetry_process.py` | **Keep** | Useful for desktop batch processing |

---

## 16. Sources

### Structure from Motion
- Schonberger & Frahm. "Structure-from-Motion Revisited." CVPR 2016. [colmap/colmap](https://github.com/colmap/colmap)
- Pan et al. "Global Structure-from-Motion Revisited." ECCV 2024. [colmap/glomap](https://github.com/colmap/glomap)
- Wang, Chen et al. "VGGT: Visual Geometry Grounded Transformer." CVPR 2025 Best Paper. [facebookresearch/vggt](https://github.com/facebookresearch/vggt)
- Wang, Karaev et al. "VGGSfM: Visual Geometry Grounded Deep Structure from Motion." 2024. [facebookresearch/vggsfm](https://github.com/facebookresearch/vggsfm)
- "DUSt3R: Geometric 3D Vision Made Easy." CVPR 2024. [naver/dust3r](https://github.com/naver/dust3r)
- "MASt3R: Grounding Image Matching in 3D." ECCV 2024. [naver/mast3r](https://github.com/naver/mast3r)
- Liu et al. Regist3R. ACM MM 2025. [Liu-SD/Regist3R](https://github.com/Liu-SD/Regist3R)
- Brachmann et al. ACE0. ECCV 2024 Oral. [nianticlabs/acezero](https://github.com/nianticlabs/acezero)
- Smith et al. "FlowMap." 3DV 2025. [dcharatan/flowmap](https://github.com/dcharatan/flowmap)
- Wang et al. "PoseDiffusion." ICCV 2023. [facebookresearch/PoseDiffusion](https://github.com/facebookresearch/PoseDiffusion)
- Lindenberger et al. "Pixel-Perfect SfM." ICCV 2021 Best Student Paper. [cvg/pixel-perfect-sfm](https://github.com/cvg/pixel-perfect-sfm)

### Feature Detection & Matching
- DeTone et al. "SuperPoint." CVPRW 2018. [magicleap/SuperPointPretrainedNetwork](https://github.com/magicleap/SuperPointPretrainedNetwork)
- Sarlin et al. "SuperGlue." CVPR 2020.
- Lindenberger et al. "LightGlue." ICCV 2023. [cvg/LightGlue](https://github.com/cvg/LightGlue)
- Sun et al. "LoFTR." CVPR 2021. [zju3dv/LoFTR](https://github.com/zju3dv/LoFTR)
- Edstedt et al. "RoMa." CVPR 2024. [Parskatt/RoMa](https://github.com/Parskatt/RoMa)
- Tyszkiewicz et al. "DISK." NeurIPS 2020. [cvlab-epfl/disk](https://github.com/cvlab-epfl/disk)
- Zhao et al. "ALIKED." IEEE T-IM 2023.

### 3D Gaussian Splatting
- Kerbl et al. "3D Gaussian Splatting for Real-Time Radiance Field Rendering." SIGGRAPH 2023. [graphdeco-inria/gaussian-splatting](https://github.com/graphdeco-inria/gaussian-splatting)
- Huang et al. "2D Gaussian Splatting for Geometrically Accurate Radiance Fields." SIGGRAPH 2024. [hbb1/2d-gaussian-splatting](https://github.com/hbb1/2d-gaussian-splatting)
- LightGaussian. NeurIPS 2024. [VITA-Group/LightGaussian](https://github.com/VITA-Group/LightGaussian)
- Compact-3DGS. CVPR 2024. [maincold2/Compact-3DGS](https://github.com/maincold2/Compact-3DGS)
- Khronos KHR_gaussian_splatting. Release Candidate Feb 2026. [khronos.org](https://www.khronos.org/news/press/gltf-gaussian-splatting-press-release)
- "Immersive heritage through Gaussian Splatting." Frontiers in Computer Science, 2025.
- "3DGS for damaged cultural heritage." Nature Heritage Science, 2025. DOI: 10.1038/s40494-025-02063-5
- "Super-resolution 3DGS for heritage." Nature Heritage Science, 2026. DOI: 10.1038/s40494-026-02355-4
- 3DGS Compression Survey. [w-m.github.io/3dgs-compression-survey](https://w-m.github.io/3dgs-compression-survey/)

### Neural Radiance Fields
- Muller et al. "Instant-NGP." SIGGRAPH 2022. [NVlabs/instant-ngp](https://github.com/NVlabs/instant-ngp)
- Barron et al. "Zip-NeRF." ICCV 2023.
- "NeRF2Mesh." ICCV 2023. [ashawkey/nerf2mesh](https://github.com/ashawkey/nerf2mesh)
- "MobileNeRF." CVPR 2023.
- "NeuS2." ICCV 2023.
- "NeuralAngelo." NVIDIA, CVPR 2023.

### Multi-View Stereo & Surface Reconstruction
- Wang et al. "PatchmatchNet." CVPR 2021 Oral. [FangjinhuaWang/PatchmatchNet](https://github.com/FangjinhuaWang/PatchmatchNet)
- "SimpleRecon." Niantic, ECCV 2022. [nianticlabs/simplerecon](https://github.com/nianticlabs/simplerecon)
- Kazhdan & Hoppe. "Screened Poisson Surface Reconstruction." SIGGRAPH 2013.
- Open3D Documentation. [open3d.org](https://www.open3d.org/docs/release/tutorial/geometry/surface_reconstruction.html)

### AI-Enhanced 3D
- Yang et al. "Depth Anything V2." 2024. [depth-anything-v2.github.io](https://depth-anything-v2.github.io/)
- "InstantMesh." TencentARC, 2024. [TencentARC/InstantMesh](https://github.com/TencentARC/InstantMesh)
- Long et al. "Wonder3D." CVPR 2024.
- Tang et al. "DreamGaussian." 2023. [dreamgaussian/dreamgaussian](https://github.com/dreamgaussian/dreamgaussian)
- Yi et al. "GaussianDreamer." CVPR 2024. [hustvl/GaussianDreamer](https://github.com/hustvl/GaussianDreamer)

### SLAM
- Campos et al. "ORB-SLAM3." T-RO 2021. [UZ-SLAMLab/ORB_SLAM3](https://github.com/UZ-SLAMLab/ORB_SLAM3)
- "MASt3R-SLAM." 2025. [edexheim.github.io/mast3r-slam](https://edexheim.github.io/mast3r-slam/)

### Depth Estimation
- Ranftl et al. "MiDaS." 2020+. [isl-org/MiDaS](https://github.com/isl-org/MiDaS)
- "ZoeDepth." 2023.

### Web Viewers & Formats
- antimatter15/splat. [antimatter15/splat](https://github.com/antimatter15/splat)
- gsplat.js. [huggingface/gsplat.js](https://github.com/huggingface/gsplat.js)
- GaussianSplats3D. [mkkellogg/GaussianSplats3D](https://github.com/mkkellogg/GaussianSplats3D)
- Potree. [potree/potree](https://github.com/potree/potree)
- gocesiumtiler. [mfbonfigli/gocesiumtiler](https://github.com/mfbonfigli/gocesiumtiler)

### Archaeological Heritage
- "Single-image 3D reconstruction of painted potteries." Nature Heritage Science, 2025. DOI: 10.1038/s40494-025-02114-x
- GCP reliability research, 2025. DOI: 10.1080/10095020.2025.2451204
- DUSt3R/MASt3R/VGGT evaluation for photogrammetry. 2025. DOI: 10.1080/10095020.2025.2597491
- ICOMOS Charter for Archaeological Heritage Management, 1990.
- CIDOC-CRM. ISO 21127:2014.

---

*This document was compiled from extensive web research, academic literature review, and analysis of the AncientVision codebase. All GitHub repositories and papers referenced are open-source or publicly available. Research conducted February 2026.*
