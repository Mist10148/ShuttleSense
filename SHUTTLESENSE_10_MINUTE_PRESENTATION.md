### General Objective

To develop and evaluate *ShuttleSense*, a computer-vision-based badminton analysis application that integrates *shuttlecock tracking, player pose estimation, stroke classification, court-based visualization, and AI-assisted coaching feedback* to support badminton performance review.

### Specific Objectives

1. *Shuttlecock Tracking:* To estimate and visualize shuttlecock movement and trajectories from badminton video frames using computer-vision techniques.

2. *Stroke Classification:* To implement and compare *1D CNN, LSTM, and Random Forest* algorithms for classifying six badminton stroke types and evaluating their performance.

3. *Player Movement Analysis:* To apply player pose estimation and court calibration to support movement analysis, spatial visualization, and available form-related observations.

4. *AI-Assisted Coaching:* To integrate an *AI Coach* that interprets CNN-generated stroke analysis summaries alongside predefined reference data to produce contextual performance insights and suggested areas for improvement.

5. *Application Implementation:* To integrate these capabilities into an accessible application supporting *recorded-rally analysis and live camera-based processing*, with visual results for performance review.

Introduciton and problem indotruction

"How do you accurately analyze a badminton rally when the shuttlecock moves so quickly that even tracking it becomes a challenge?"
According to Chen and Wang (2023), the shuttlecock's small size, rapid movement, and motion blur make tracking difficult.
Meanwhile, Liang et al. (2026) highlight that traditional badminton video analysis is time-consuming, subjective, and difficult to scale.
But beyond identifying strokes, another challenge remains: How can players turn these observations into meaningful improvements?
This is where ShuttleSense comes in.
ShuttleSense is a computer-vision-based badminton analysis application that integrates shuttle tracking, stroke classification, player pose estimation, and visual feedback.
It also features an AI Coach that uses CNN-generated stroke summaries and predefined reference data to provide contextual performance insights and improvement suggestions.
Ultimately, ShuttleSense aims to transform badminton footage into structured, accessible, and actionable feedback, supporting players and coaches in reviewing performance.



# ShuttleSense: 10-Minute Presentation Reference Content 

This document provides the explanations and evidence for a 10-minute presentation of ShuttleSense. It follows the supplied eight-part outline and prioritizes the algorithm comparison, interpretation, and working application. It is a research reference rather than a word-for-word script: the supporting details are fuller than what can fit on slides or be spoken in ten minutes. The [original presentation reference](SHUTTLESENSE_PRESENTATION_REFERENCE.md) provides additional background and a longer explanation of the processing and rendering pipeline.

## Presentation structure and grading coverage

| Section | Suggested slides | Time | Rubric coverage stated in outline |
| --- | --- | ---: | --- |
| 1. Introduction & Problem Definition | 1 | 1:00 | Criterion 1 |
| 2. Dataset Collection & Preprocessing | 2 | 1:00 | Criteria 2 and 3 |
| 3. Methodology & Algorithm Selection | 3 | 1:12 | Criteria 4 and 5 |
| 4. Model Evaluation & Algorithm Comparison | 4–5 | 1:48 | Criteria 4, 6 and 7 |
| 5. System Features | 6 | 1:00 | Criterion 8, partial |
| 6. Application Demonstration | 7–8 | 1:30 | Criterion 8 |
| 7. Results, Interpretation & Limitations | 9 | 2:00 | Criterion 7 |
| 8. Conclusion | 10 | 0:30 | Criteria 1 and 9 |
| **Total** | **10 slides** | **10:00** | **All nine criteria addressed according to the supplied outline** |

The numerical comparison belongs in Section 4. Section 7 explains what those findings mean for the objectives and where the evidence stops. The demo focuses on **Watch & Analyze** and **Go live**, consistent with the earlier reference.

---

## 1. Introduction & Problem Definition — 1:00

Badminton rallies combine fast player movements with a small, quickly moving shuttlecock. A player or coach reviewing a recording may have to replay it repeatedly to follow the shuttle, identify strokes and observe player movement. The practical problem is how to organize those observations into a form that is easier to review and discuss.

ShuttleSense is a computer-vision system intended to support that review. It estimates the shuttle's trajectory and player pose, identifies likely hits, classifies strokes and presents the resulting information through video and court-based visualizations. The intended users include student and amateur players, instructors and coaches. These are project motivations and intended benefits; the repository does not establish a measured improvement in skill or a specific amount of time saved. [Project objectives and users](docs/PRD.md#goals-and-users).

The main objectives are to:

1. **Track and visualize the shuttle** so its movement is easier to follow.
2. **Classify strokes** into smash, clear, drop, net shot, lift and serve.
3. **Use player pose and court context** to support movement review, estimated match information and heuristic form feedback.
4. **Present outputs in an application** that lets users analyze a recorded rally or work with a live camera feed.

The result is an assistive analysis tool. Its stroke labels, speed estimates, form cues and line calls are estimates that can be affected by missing detections, camera perspective and calibration. Line calls are not official decisions, and form feedback is not medical or certified professional advice. [Limitations](README.md#limitations).

**Slide visual:** A rally image and a simple connection between the problem and three actions: track, classify and review.

## 2. Dataset Collection & Preprocessing — 1:00

### Dataset source and organization

The team's three stroke classifiers were trained on **pre-extracted ShuttleSet features published with the Badminton Stroke-type Transformer (BST) project**. ShuttleSet is a human-annotated badminton singles dataset; the BST feature release provides pose keypoints and shuttle positions in time windows around strokes. The team mapped the relevant labels into its six stroke classes and trained its own classifiers on those features. The team did not train the three pretrained perception models from scratch for this classifier comparison. [ShuttleSet paper](https://arxiv.org/abs/2306.04948), [BST feature source](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer), [classifier evaluation](docs/results/strokes.md).

The reported comparison uses BST's **match-based split**: 23,723 training strokes, 3,821 validation strokes and 3,136 test strokes. Training fits model parameters; validation helps select settings; the test split assesses performance on separate matches. Splitting by match reduces overlap between training and test footage, though it does not prove generalization to different filming conditions. A separate team-created annotation split in [dataset statistics](docs/results/dataset.md) has different counts and must not be combined with this comparison. [Split and results](docs/results/strokes.md).

### Preparing the data for the classifiers

The classifier input is a temporal window around a hit. In the standard pose-and-shuttle representation, each frame contains **39 values**: 34 coordinates from 17 body keypoints, plus shuttle x/y position, visibility and changes in x/y position. The shipped model uses pose coordinates relative to the player's bounding box and normalized by its diagonal; shuttle coordinates are normalized to the image dimensions. The usual window contains 30 time steps at the configured 30 fps window rate. Missing observations are represented in the feature construction, including a shuttle-visibility value; this does not mean an unseen location is known. [Feature construction](backend/shuttlesense/strokes/features.py), [CNN configuration](backend/configs/stroke_cnn.yaml).

For training, the loader can apply transformations such as horizontal flips, small shifts in time and noise. Additional augmentation options such as missing joints or shuttle gaps are configuration-dependent; they should not be presented as identical across all three experiments. These transformations are intended to make the trained models less sensitive to certain variations, but broadcast-only evaluation cannot prove that they solve the phone-footage domain gap. [Training data code](backend/shuttlesense/strokes/dataset.py), [evaluation details](docs/results/strokes.md).

A useful example is a **30 × 39** array: its rows represent successive moments around one hit, and its columns represent pose and shuttle features. It captures motion through time rather than treating a stroke as one still image. Class imbalance is another reason to report class-balanced metrics alongside overall accuracy.

**Slide visual:** Dataset source → match split → 30 × 39 feature window. Show the six labels as a small list.

## 3. Methodology & Algorithm Selection — 1:12

### Pipeline and three pretrained perception models

```text
Recorded rally or live camera frames
  → TrackNetV3: shuttle positions
  → YOLOX: player regions → RTMPose: body keypoints
  → likely hit + pose/shuttle time window
  → selected stroke classifier → label and confidence
  → court analysis, visualizations and available rendered results
```

- **TrackNetV3** estimates the position of the small shuttlecock over video frames. Its trajectory helps display shuttle movement and contributes to hit detection and stroke features. Its pretrained system includes trajectory rectification.
- **YOLOX** detects people in the video, supplying player regions for subsequent pose analysis.
- **RTMPose** estimates body keypoints. These approximate joint positions describe player motion for stroke classification and rule-based form cues.

The current README and technology stack identify YOLOX, while an older PRD passage names RTMDet; the active detector in a specific run must be confirmed from its configuration. The pretrained perception models and the **team-trained stroke classifiers** have different roles. [Model overview](README.md#models), [technology stack](docs/TECH_STACK.md), [TrackNetV3 project](https://github.com/qaz812345/TrackNetV3).

### Why compare the classifiers?

The comparison tests three ways to interpret movement around a hit:

- **1D CNN:** learns local patterns across the ordered feature sequence with temporal convolution filters.
- **LSTM:** uses recurrent state to process the sequence and capture information across time.
- **Random Forest:** aggregates decision trees using engineered summary features of the window.

They address the same six-class problem using different representations. The reported CNN has the strongest mean class-balanced score among the three individual models in the selected comparison, so it is a defensible leading choice. The application also supports other model choices where available; the comparison does not imply they were removed. [Model implementation](backend/shuttlesense/strokes/model.py), [forest implementation](backend/shuttlesense/strokes/rf.py), [comparison](docs/results/strokes.md).

The client is implemented in **Dart/Flutter**, which provides the interface across supported devices; the analysis backend uses **Python**, FastAPI, OpenCV, NumPy, PyTorch and ONNX Runtime. This separates user interaction and visualization from model inference and processing. [Technology stack](docs/TECH_STACK.md).

**Slide visual:** A compact flow diagram with the three pretrained model roles above and the CNN, LSTM and Random Forest comparison below.

## 4. Model Evaluation & Algorithm Comparison — 1:48

### Actual reported accuracy results

The table below uses the November 16 **model-only** results on the same BST test split of 3,136 broadcast-match strokes. Values are mean ± standard deviation over three training seeds; the spread is not a confidence interval for new footage. [Results and methodology](docs/results/strokes.md).

| Algorithm | Accuracy | Macro accuracy | Macro F1 |
| --- | ---: | ---: | ---: |
| **1D CNN** | **91.9% ± 0.5%** | **91.2% ± 0.6%** | **91.0% ± 0.6%** |
| LSTM | 91.1% ± 0.5% | 90.2% ± 0.5% | 90.0% ± 0.6% |
| Random Forest | 86.7% ± 0.2% | 84.7% ± 0.3% | 85.5% ± 0.2% |

Accuracy is the share of all predictions that match the reference. The report's **macro accuracy** averages recall across the six classes; **macro F1** averages each class's F1, which combines its precision and recall. Macro metrics help expose weaknesses on less frequent classes that can be hidden by overall accuracy.

**Why CNN?** It has the highest mean macro accuracy and macro F1 of the individual classifiers in this common reported comparison. The LSTM is close, while the Random Forest trails on this test setup. This supports choosing the CNN as the presentation's leading individual model; it does not prove statistical significance, the fastest runtime, or superior results for all cameras and datasets. [Per-class results](docs/results/strokes.md).

The CNN is not equally reliable for every class: its reported drop F1 is **80.1% ± 1.1%**, versus **97.5% ± 0.6%** for serves. The report identifies **17% of drops classified as smashes** for the CNN. A [confusion matrix](docs/results/strokes_confusion_cnn.png) shows this kind of misclassification by comparing reference and predicted labels. Read its axis labels and normalization before interpreting any cell. [Results](docs/results/strokes.md).

### Theoretical inference time and space complexity

These expressions describe **one stroke window**, at inference, for a batch of one. They are architecture-based estimates, not measured processing times, memory consumption, training costs or whole-video pipeline complexity. Feature construction, image decoding, tracking, court analysis, test-time augmentation, ensemble execution and rendering are excluded unless identified below. Actual GPU latency also depends on implementation, transfers and hardware.

Let `T` be the number of time steps, `F` the input features, `Kᵢ` the convolution kernel length, `Cᵢ` the output channels of convolution layer `i` (`C₀ = F`), `Tᵢ` its output length, `L` the number of LSTM layers, `H` the hidden width, `R` the number of trees, `D` maximum tree depth, `N` total tree nodes, `Q` the number of output classes and `P` the number of model parameters. Constants such as four LSTM gates and two directions are suppressed in Big-O notation. Parameters and working memory are both included in the space descriptions.

| Model | Inference time per window | Space: model plus working memory | Explanation |
| --- | --- | --- | --- |
| **1D CNN** | `O(Σᵢ Tᵢ Kᵢ Cᵢ₋₁ Cᵢ + C_last Q)` | `O(P + T F + maxᵢ(Tᵢ Cᵢ) + Q)` | Each convolution slides filters across time and combines input/output channels. The model stores its weights and input/intermediate activations. |
| **LSTM** | `O(T(FH + LH²) + HQ)` | `O(P + T F + T L H + Q)` | The input projection and recurrent layers process each step; the implementation is bidirectional and pools sequence outputs. Space conservatively includes sequence activations and model weights. |
| **Random Forest** | `O(TF + R(D + Q))` | `O(NQ + R + TF + Q)` | `O(TF)` represents summary-feature generation for this fixed feature recipe; each tree follows a path of at most `D` nodes and contributes a `Q`-class distribution. Flat arrays store nodes, roots and leaf values. |

For the forest, `NQ` is a conservative bound including the stored class-value array at nodes; exact memory depends on serialized arrays and dtypes. The formula assumes the project's fixed summary-feature recipe and six classes rather than an arbitrary feature-engineering algorithm. A batched or training execution uses additional memory. Pooling, temporary workspaces and implementation-specific allocations can change peak usage; the expressions are useful for explaining how costs scale, not for claiming an observed speed or memory winner. [CNN/LSTM code](backend/shuttlesense/strokes/model.py), [forest arrays and prediction](backend/shuttlesense/strokes/rf.py), [features](backend/shuttlesense/strokes/features.py).

With the project's fixed 30-step input and fixed deployed model sizes, these are fixed-cost operations per classified hit for a given configuration; a longer match can contain more windows. The LSTM's recurrent time dependency, the CNN's temporal convolutions and the forest's tree traversals are different computational structures, but no like-for-like latency benchmark here establishes a performance ranking.

**Slide visual:** A bar chart or compact table for macro accuracy, plus the CNN confusion-matrix excerpt. Put complexity formulas in a small comparison table or speaker notes, and explain variables verbally rather than reading every symbol.

## 5. System Features — 1:00

The two workflows highlighted in the presentation are **Watch & Analyze**, which plays a selected recording while it is analyzed, and **Go live**, which sends camera frames to the backend during a session. Availability depends on the platform, backend capabilities and installed models. [Mode chooser](app/lib/features/mode/mode_screen.dart).

| Feature | What the user sees or does | How the implementation supports it |
| --- | --- | --- |
| **Recorded-rally analysis** | In Watch & Analyze, select a video, confirm match format and calibrate the court; watch the recording with available analysis. | Tracking and pose stages process frames; the app offers Real time or Analyze every frame. The latter waits for each normalized frame, although high-frame-rate input may still be sampled. |
| **Live analysis** | In Go live, point a camera at the court, configure the session and view available feedback during play. | Camera frames travel to the backend, which returns available events and overlays. A stroke-model selector appears in the live setup when supported. |
| **Video and stroke results** | Review available trajectories, pose overlays, stroke labels, timeline and rendered video. | TrackNetV3 and RTMPose supply movement features; the selected stroke classifier estimates labels for likely hits. Rendering draws available overlays from the analysis record. |
| **Court view and heatmap** | When court calibration and required data are available, view positions and a heatmap on the court visualization. | Court projection maps positions to a grid; the heatmap summarizes where players spent time, with a separate landing distribution where applicable. It is a spatial aggregation, not a CNN prediction or TrackNetV3's internal detection heatmap. |

For player heatmaps, the backend's documented method accumulates in-rally time on a **0.25 m court grid**, spreading estimated locations with a Gaussian to represent spatial uncertainty; landing maps count estimated landing locations. The results view has a Heatmap mode. The available visualization depends on calibration and the data generated by the session. [Heatmap calculation](backend/shuttlesense/analytics/heatmap.py), [court view](app/lib/features/results/widgets/court_minimap.dart).

Watch's experimental faster-player option can affect detections and has not passed the project's held-out accuracy gate. Live feedback and line calls remain estimates, not certified calls. [Watch validation](docs/results/watch_phase7_validation_report.md), [project limitations](README.md#limitations).

**Slide visual:** Four screenshots or small previews: Watch, Live, annotated video/stroke timeline, and court heatmap. Label any fixture or synthetic screenshot accurately.

## 6. Application Demonstration — 1:30

This sequence adapts the [existing demonstration reference](SHUTTLESENSE_PRESENTATION_REFERENCE.md#8-application-demonstration--conclusion--130). It emphasizes the two workflows and actual outputs, rather than spending the entire demonstration navigating menus.

| Time | Demonstration | Explanation |
| --- | --- | --- |
| **0:00–0:10** | Show **Watch & Analyze** and **Go live**. | One analyzes a recording while it plays; the other receives camera frames during a session. Both need a compatible backend. |
| **0:10–0:35** | Show a prepared Watch session with its clip, match format, court calibration and a visible result. | Identify whether Real time or Analyze every frame is active; explain that playback and analysis follow that setting. |
| **0:35–1:00** | Show the Go live camera view and prepared match/court settings; start or show the active session when ready. | The camera sends frames to the backend. If the model selector is available, identify the chosen stroke classifier separately from the workflow. |
| **1:00–1:20** | Show an actual available trajectory, stroke entry, rendered result or court heatmap from a demonstrated session. | Connect the visual to tracking, pose and stroke classification; explain that the heatmap summarizes positions and that displayed labels are estimates. |
| **1:20–1:30** | State the result's meaning and limitation. | The system organizes information for review; the reported classifier score does not establish accuracy on this particular live camera or recording. |

A prepared result avoids waiting for a full run. If a saved result, prior recording, synthetic example or fixture is used, identify it accurately; do not imply that a prior recording is a live run. If the shown result used a different mode or classifier from the current selection, state that distinction. Show only the outputs actually present. [Watch interface](app/lib/features/watch/watch_screen.dart), [live setup](app/lib/features/live/live_screen.dart), [integration validation](docs/results/watch_phase7_validation_report.md).

## 7. Results, Interpretation & Limitations — 2:00

### What the comparison means

The CNN's leading macro accuracy supports its selection as a strong individual classifier for the project's six-label task **on the evaluated broadcast-derived features**. Macro metrics matter because each class contributes to the average, even when some classes are more frequent. The lower drop F1 and drop-to-smash confusion show why the team should inspect class-specific results rather than assuming that every stroke is recognized equally well. The LSTM remains a strong alternative, while the forest's weaker result shows the trade-off of this particular summary-feature approach in the reported setup.

The CNN's pose-only ablation reported **77.5% ± 0.7% macro accuracy**, compared with **91.2% ± 0.6%** using pose and shuttle features in the model-only comparison. That difference supports the usefulness of combining pose and shuttle information on this test setup; it does not prove the same gain on phone video or when shuttle tracking fails. [Classifier and ablation results](docs/results/strokes.md).

Context and ensemble experiments are separate configurations. The [context report](docs/results/stroke_context.md) reports CNN macro accuracy of 93.4% and ensemble macro accuracy of 93.8% with rally/court context for shipped weights. Those are not the three-seed model-only means in Section 4. The later [cross-validation report](docs/results/strokes_cv.md) uses another procedure and includes a fourth test-split read; its values should not be mixed into the common November 16 table without explaining the change.

### Data structures: how the implementation produces useful outputs

- **Feature array and tensor:** a stroke window begins as ordered time × feature values, then the CNN receives a tensor shaped **batch × features × time**. The order preserves how pose and shuttle motion evolve around a hit. [Feature code](backend/shuttlesense/strokes/features.py), [model code](backend/shuttlesense/strokes/model.py).
- **Convolution weights and feature maps:** arrays of learned filters scan across time, producing intermediate feature maps that represent motion patterns. The CNN uses Conv1d blocks, max pooling, global average pooling and a final linear layer to generate scores for the six labels. These scores support the stroke label and confidence displayed in the timeline or result. [Model implementation](backend/shuttlesense/strokes/model.py).
- **Clip record and frame arrays:** structured records retain frame-level shuttle, player and event information so downstream analysis and video overlays can use the same estimates. [System workflow](README.md#how-it-works).
- **Court grid:** a two-dimensional grid accumulates projected player locations or estimated landing positions for court heatmaps. This calculation uses court and rally data; it is not performed by the stroke CNN. [Heatmap implementation](backend/shuttlesense/analytics/heatmap.py).

### CPU, GPU, CUDA and rendered video

The **CPU** prepares and coordinates work, including video/frame handling, numerical processing and drawing annotations in the documented export path. When configured with a compatible NVIDIA device and dependencies, supported PyTorch and ONNX Runtime inference can use the **GPU through CUDA**. In the documented Watch diagnostic, the detector used CUDA and pose used TensorRT RTX, with fallback paths; the actual provider and node assignment must be checked for each environment. CPU/GPU transfers, synchronization and startup still contribute to total processing time. CUDA is a computing platform, not the stroke algorithm or a promise that every operation runs on the GPU. [Performance roadmap](SHUTTLESENSE_PERFORMANCE_ROADMAP.md), [pose profile](docs/results/watch_phase3_pose_profile.md).

After analysis, the renderer draws available annotations onto source frames using the record. The resulting frames are encoded into a playable video. **FFmpeg libx264** is the default CPU-based H.264 encoder; optional **h264_nvenc** uses NVIDIA's hardware video encoder when available. NVENC encoding is distinct from CUDA model inference and does not imply overlay drawing runs on the GPU. The project kept libx264 as default because the small initial benchmark did not establish a repeatable improvement at comparable quality. [Renderer](backend/shuttlesense/render/overlays.py), [writer](backend/shuttlesense/render/writer.py), [export benchmark](docs/results/watch_phase6_export_benchmark.md).

### Limitations and future outlook

- **Dataset and evaluation:** the reported test uses broadcast singles features, and the test split was read repeatedly during development. Evaluate on independently held-out matches and consented, labeled phone footage before generalizing the score.
- **Detection and calibration:** small or occluded shuttles, overlapping players, camera angle and inaccurate corners can propagate errors. Test tracking, pose, hit detection, classification and court mapping separately and end to end.
- **Doubles and live use:** labeled doubles accuracy and full physical-device performance remain open. Add representative doubles clips, device tests and latency measurements under realistic conditions.
- **Performance:** CPU/GPU workload, encoding and data transfers must be measured on representative recordings; compare candidate optimizations with matched quality and accuracy rather than assuming GPU use guarantees a speedup.
- **Output interpretation:** one-camera speed and line calls are estimates; form cues are heuristic. Keep uncertainty visible and allow human review.

Short model-backed smoke tests exist, but the [integration report](docs/results/watch_phase7_validation_report.md) does not establish complete promotion or held-out player, shuttle and event accuracy. Those checks are meaningful next steps rather than results already achieved.

**Slide visual:** One diagram linking feature tensors → CNN → stroke label and court grid → heatmap, alongside a compact CPU/GPU/rendering diagram and three limitations.

## 8. Conclusion — 0:30

ShuttleSense addresses the difficulty of reviewing fast badminton rallies by combining shuttle tracking, player pose, stroke classification and visual summaries. In the reported three-seed comparison on broadcast-derived test features, the **1D CNN achieved 91.9% overall accuracy and 91.2% macro accuracy**, making it the strongest individual model in that comparison.

For a single window, its convolutional work scales as **`O(Σᵢ Tᵢ Kᵢ Cᵢ₋₁ Cᵢ)`**, and its model-plus-working space scales as **`O(P + T F + maxᵢ(Tᵢ Cᵢ))`**, with the fixed six-class head omitted here for brevity. These are theoretical inference bounds, not measured end-to-end times. Supported model inference can use NVIDIA GPU acceleration through CUDA; CPU work still prepares data and draws overlays, and encoding is a separate stage. Future labeled phone and doubles evaluations will determine how well the system generalizes beyond its current evidence.

## Sources and presentation notes

- [Existing ShuttleSense presentation reference](SHUTTLESENSE_PRESENTATION_REFERENCE.md)
- [Project workflow, models and limitations](README.md), [project objectives](docs/PRD.md), [technology stack](docs/TECH_STACK.md)
- [ShuttleSet paper](https://arxiv.org/abs/2306.04948), [BST feature source](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer), [TrackNetV3 project](https://github.com/qaz812345/TrackNetV3)
- [Classifier results and confusion matrices](docs/results/strokes.md), [cross-validation](docs/results/strokes_cv.md), [context and ensemble](docs/results/stroke_context.md)
- [CNN/LSTM implementation](backend/shuttlesense/strokes/model.py), [feature representation](backend/shuttlesense/strokes/features.py), [Random Forest](backend/shuttlesense/strokes/rf.py)
- [Court heatmap](backend/shuttlesense/analytics/heatmap.py), [renderer](backend/shuttlesense/render/overlays.py), [export benchmark](docs/results/watch_phase6_export_benchmark.md), [integration validation](docs/results/watch_phase7_validation_report.md)

The supplied outline also asks for accompanying documentation of at most 15 pages, 12-point font and long bond paper, with organized code and reproducible methodology. This Markdown file is a presentation reference; those page-layout requirements apply when preparing a separate formatted document and are not automatically guaranteed by Markdown.
