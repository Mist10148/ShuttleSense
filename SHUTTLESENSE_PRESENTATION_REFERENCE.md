# ShuttleSense Presentation: Explanations and Supporting Evidence

This document explains the substance behind each part of the presentation using the ShuttleSense repository. It is intended as a reference for understanding and preparing individual explanations; the paragraphs contain more detail than can be spoken within the time limit. Statements about measured results identify the dataset and conditions so they can be presented accurately.

## Presentation structure

| Section | Suggested slides | Time |
| --- | --- | ---: |
| 1. Problem Definition | 1 | 0:55 |
| 2. Proposed Solution & System Overview | 2 | 1:10 |
| 3. Application Features & Analysis Choices | 3 | 0:45 |
| 4. Dataset Collection & Pretrained ML Models | 4 | 1:25 |
| 5. Algorithm Selection, Comparison & Results | 5-6 | 2:00 |
| 6. Programming Language & Implementation | 7 | 0:45 |
| 7. Data Preprocessing, Processing Pipeline & Output Evaluation | 8 | 1:00 |
| 8. Application Demonstration & Conclusion | 9-10 | 1:30 |
| **Total** | **10 slides maximum** | **9:30** |

The eight allocations total 9:30, with an additional 30 seconds of buffer. The feature overview introduces the capabilities; the demonstration makes the analysis choices and resulting workflow concrete. This reference contains more detail than can be spoken in the allotted time.

---

## 1. Problem Definition — 0:55

### The problem ShuttleSense addresses

Badminton is a fast-moving sport in which players, coaches and viewers must follow a small shuttlecock as well as the movement and technique of the players. A single rally can contain several different strokes and rapid changes in shuttle direction. Watching a recording gives a person access to the rally, but identifying and organizing those events manually can require repeatedly pausing and replaying the footage. This makes it harder to review stroke choices, movement and rally patterns in a consistent, accessible format.

ShuttleSense responds to this problem by turning video into an organized set of estimated observations. Instead of requiring a viewer to infer every event solely by watching the footage, the application is designed to identify the shuttle's movement, estimate player poses, classify strokes and present related match information. Its intended users include student and amateur players who want to review their play, and instructors or coaches who want a convenient starting point for discussing a rally. The project also provides a technical demonstration of how computer vision and machine learning can work together in a sports-analysis application. [Project goals and users](docs/PRD.md#goals-and-users).

The problem statement is a **practical motivation**, not a measured claim that ShuttleSense saves a particular number of minutes or improves a player's performance. The repository does not establish those outcomes through a user study.

### Objectives and their justification

1. **Track the shuttlecock and show its trajectory.** Knowing where the shuttle appears across frames gives the rest of the system information about movement and possible changes in direction. A visible trail also helps a user follow an object that can be difficult to see at normal playback speed.
2. **Classify strokes into six categories.** Labels for smash, clear, drop, net shot, lift and serve make it possible to summarize which types of shot occurred. Such labels give players and coaches a way to discuss a rally beyond simply viewing the video.
3. **Estimate player pose and provide form-related cues.** Body keypoints represent approximate positions of joints. The system uses these estimates in stroke classification and in rules that produce form feedback, making player movement part of the review rather than focusing only on the shuttle.
4. **Place actions in court and rally context.** Court mapping, estimated speed, rally information and assisted scoring organize individual events into a broader view of what happened during play.
5. **Present the analysis through an accessible application.** A Flutter client provides screens for submitting footage and reviewing outputs, while a connected backend performs the computational work.

These are project objectives, not a guarantee that every output is correct. In particular, form feedback is heuristic guidance, speed is estimated from a single camera, and automated line calls are not official decisions. [Goals](docs/PRD.md#goals-and-users), [limitations](README.md#limitations).

**Presentation emphasis:** Describe the need for accessible, structured review; then connect tracking, classification and visualization to that need. The detailed objective list supports the explanation and does not need to be read in full.

## 2. Proposed Solution & System Overview — 1:10

### What the application does

ShuttleSense is a computer-vision application that analyzes badminton footage and presents estimated information about a rally. In Watch & Analyze, the user selects a recorded video and watches it while the backend analyzes frames. In Go live, the client sends camera frames to the backend and receives analysis events during the session. Court calibration supports court-related analysis in either workflow. [System workflow](README.md#how-it-works).

The distinction between the **client** and the **backend** is important. The client handles interaction and presentation: selecting a video, showing progress, playing results and displaying visual summaries. The backend performs the computationally intensive processing, including model inference, court geometry and result generation. A phone or tablet therefore needs a connection to the backend; the project does not claim that all models run locally on the mobile device. [Technology overview](docs/TECH_STACK.md#overview).

### How the components work together

```text
Video or live camera frames
        ↓
Shuttle tracking + player detection + pose estimation
        ↓
Frame-by-frame information, court mapping and likely hit detection
        ↓
Stroke classification + rally analysis + heuristic form feedback
        ↓
Annotated video, stroke information, court view and summaries
```

The stages have different responsibilities. **TrackNetV3** estimates where the shuttle is in the video. A person detector identifies player regions, and **RTMPose** estimates body keypoints. The backend uses shuttle motion and player position to help locate likely hits, then applies a selected stroke classifier to pose and shuttle information around each hit. Court-corner calibration supports a transformation from the image view to an approximate court view. The application combines the available results into visual and structured outputs. [Repository architecture](README.md#how-it-works).

For example, if a player swings and the shuttle changes direction nearby, the system can identify a likely hit and analyze the surrounding movement. A classifier may label that window as a smash, and the result can be displayed alongside the video or other rally information. The label remains an estimate: if the shuttle was not tracked correctly or the player's body was obscured, that error can influence later stages.

### Why this is an appropriate response to the problem

The proposed solution joins several pieces of information that would otherwise need to be observed and organized manually. The trajectory helps the user see movement; the stroke label describes an event; and the court view and summary provide context. These capabilities support review, but the classifier's reported performance alone does not prove that the complete system is equally accurate on every video or that it improves a player's skill. Its results are best understood as assistance for a person reviewing play.

## 3. Application Features & Analysis Choices — 0:45

### The two workflows featured in the presentation

The demonstration focuses on **Watch & Analyze** and **Go live**. Both connect the Flutter client to the analysis backend, but they differ in where the footage comes from and how the user experiences it. Availability depends on the connected server, supported platform and installed models. [Mode chooser implementation](app/lib/features/mode/mode_screen.dart).

| Analysis choice | Input and experience | Purpose |
| --- | --- | --- |
| **Watch & Analyze** | The user selects a recorded video and watches it while the backend analyzes frames. It is available in the Windows app and supported Chrome/web setup when the backend advertises support. | Review a recorded rally while the system processes it, then inspect the available results. |
| **Go live** | The user points a supported camera at the court and starts a session. Camera frames are sent to the backend, which returns available analysis events while play continues. | Follow a session as it happens and review available live feedback and match information. |

In Watch & Analyze, **Real time** plays the recording at normal speed while normalized frames are analyzed in the background. **Analyze every frame** waits for each normalized frame before continuing playback; high-frame-rate video may still be sampled. Real time does not guarantee every source frame is analyzed or that results are available immediately. Its experimental faster-player option can change detections and results and is not always faster. [Watch controls](app/lib/features/watch/watch_screen.dart), [integration validation](docs/results/watch_phase7_validation_report.md).

### Capabilities visible across the workflows

- **Motion analysis:** shuttle tracking, player detection, pose estimates and likely hit detection turn footage into information for following a rally and classifying strokes. Visible overlays depend on which stages and models are available.
- **Stroke and court insights:** available output can include a stroke label or timeline, confidence, stroke counts, approximate speed and a top-down court view. These are estimates derived from the footage and prior processing stages.
- **Court and match setup:** Watch lets the user confirm singles or doubles and locate or adjust court corners. The live setup provides camera preview, match settings and court calibration. Calibration supports court-dependent features; Watch explicitly notes that player detection is disabled without it. Doubles accuracy has not been established on labeled doubles footage. [Watch controls](app/lib/features/watch/watch_screen.dart), [live setup](app/lib/features/live/live_screen.dart), [limitations](README.md#limitations).
- **Assisted referee and coaching:** when available and enabled, the application can show estimated rally, score and line-call information and heuristic coaching cues. Line calls are not official, and coaching cues are not medical or certified professional advice.
- **Review:** completed or saved session information can be revisited where supported, allowing a user to connect visible events with a rally. The exact outputs depend on the workflow and successful processing.

### Analysis workflow versus stroke classifier

Watch & Analyze and Go live describe **how the footage is supplied and analyzed**. The CNN, LSTM, Random Forest and Ensemble are **stroke-classification choices**, a separate concept. The live setup includes a stroke-model field when supported by the connected server; the available models depend on what the server reports. The Watch screen should not be assumed to expose the same selector: identify the model actually used from the active configuration or recorded results. [Live setup](app/lib/features/live/live_screen.dart), [model options](app/lib/data/models/job.dart).

The feature overview explains these concepts briefly; the demonstration makes them concrete by showing a recorded rally in Watch & Analyze and the camera-based live workflow.

## 4. Dataset Collection & Pretrained ML Models — 1:25

### ShuttleSet and the features used by the team

A stroke classifier needs examples connecting motion information to known stroke labels. The project uses **ShuttleSet**, a human-annotated dataset of elite badminton singles matches, as the basis for that work. Instead of extracting every training feature from raw video for this comparison, the team used pre-extracted ShuttleSet features released with the **Badminton Stroke-type Transformer (BST)** project. Those features include RTMPose body keypoints and TrackNetV3 shuttle positions in 30-frame windows around strokes. The team mapped relevant labels into six classes: smash, clear, drop, net shot, lift and serve. [Stroke results and setup](docs/results/strokes.md), [ShuttleSet paper](https://arxiv.org/abs/2306.04948), [BST repository](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer).

This distinction matters when describing the team's contribution. ShuttleSet supplied annotated badminton data; the BST release supplied the pre-extracted features and its split; the ShuttleSense team trained and compared its own CNN, LSTM and Random Forest classifiers using those features. The three stroke classifiers should not be described as downloaded, pretrained badminton classifiers. [Model research](docs/phases/phase-11-stroke-models.md).

For the comparison reported in Section 5, the BST split contains **23,723 training strokes, 3,821 validation strokes and 3,136 test strokes**. Training data is used to fit model parameters; validation data helps compare settings; test data provides an evaluation on separate matches. Splitting by match reduces the chance that windows from the same match appear in both training and test sets, which would make the evaluation less representative of a new match. However, separate matches from a similar broadcast dataset do not prove that the model will generalize to every player or filming condition. [Stroke results](docs/results/strokes.md).

The repository also documents another, team-created annotation split with different counts. Those figures describe a different split and should not be substituted into the BST comparison. The team-created statistics also illustrate class imbalance: for example, net shots occur much more frequently than serves. A model could achieve a high overall score by performing well on common classes while doing poorly on a rarer class, which is why the evaluation includes macro metrics and per-class results. [Separate dataset statistics](docs/results/dataset.md).

### The three pretrained perception models

These models serve **perception** roles: they derive movement information from video. They are separate from the three team-trained stroke classifiers compared in the next section.

| Pretrained model | Role | Why it matters to ShuttleSense |
| --- | --- | --- |
| **TrackNetV3** | Estimates shuttlecock positions across video frames. | The shuttle is small and can be blurred or briefly hidden; a sequence of estimated positions supports trajectory visualization and downstream hit analysis. TrackNetV3 includes trajectory rectification. |
| **YOLOX** | Detects people in the video. | Player regions give the pose estimator a starting point and help associate detections with players on the court. |
| **RTMPose** | Estimates body keypoints for detected people. | Approximate joint locations describe player movement and provide inputs for stroke classification and heuristic form feedback. |

TrackNetV3 uses pretrained weights associated with the Shuttlecock Trajectory Dataset; the project does not claim to have retrained those weights for this work. YOLOX and RTMPose are used through the pose/detection stack described in the current README. An older PRD passage names RTMDet instead, so the detector in a particular demonstration must be identified from its actual configuration. [Current model overview](README.md#models), [technology stack](docs/TECH_STACK.md), [TrackNetV3 project](https://github.com/qaz812345/TrackNetV3).

### Data quality and limits

The dataset and feature source are identifiable and the stroke labels are human annotated, making the data suitable for a documented comparison. Nevertheless, annotation error, class imbalance and camera viewpoint can affect the outcome. The comparison uses broadcast matches; recordings from a phone, especially from a different angle or under different lighting, may produce different detection quality and classifier performance. The reported broadcast-feature results should therefore not be presented as measured phone-footage accuracy. [Stroke evaluation limitations](docs/results/strokes.md), [project limitations](README.md#limitations).

## 5. Algorithm Selection, Comparison & Results — 2:00

### What the algorithms are trying to predict

For each likely hit, the stroke classifier receives a time window containing pose and shuttle features. Its task is to assign one of the six stroke labels. The team evaluated three approaches to this same classification problem:

- A **one-dimensional convolutional neural network (1D CNN)** applies learned filters across a sequence. These filters can identify local temporal patterns in how the pose and shuttle features change around a hit.
- A **long short-term memory network (LSTM)** is a recurrent neural network that processes a sequence while maintaining a representation of earlier time steps. This can capture how movement develops over the window.
- A **Random Forest** combines the outputs of many decision trees. In this project it uses summary features derived from the window, rather than learning the same sequence representation as the neural models.

Each approach can learn a relationship between inputs and stroke labels, but they represent the information differently. The comparison therefore examines whether those differences produce useful changes in classification performance under a shared evaluation setup. [Classifier implementation context](docs/phases/phase-11-stroke-models.md).

### How the comparison is evaluated

**Accuracy** is the proportion of all evaluated strokes classified correctly. It is easy to understand but can be dominated by frequent classes. **Macro accuracy**, as used in the report, is the average recall across the six classes: each class contributes equally, regardless of its frequency. **Macro F1** is the average of the F1 scores for the individual classes; each class's F1 combines precision and recall. These measures give a fuller picture than overall accuracy alone when the data is imbalanced.

The following comparison is taken from the November 16 model-only report. The models were tested on the same BST test split of 3,136 strokes, and the table reports the mean and standard deviation across three training seeds. The ± values describe variation across those seeds; they are not confidence intervals for all possible matches or devices. [Source and complete results](docs/results/strokes.md).

| Stroke classifier | Accuracy | Macro accuracy | Macro F1 |
| --- | ---: | ---: | ---: |
| 1D CNN | 91.9% ± 0.5% | **91.2% ± 0.6%** | **91.0% ± 0.6%** |
| LSTM | 91.1% ± 0.5% | 90.2% ± 0.5% | 90.0% ± 0.6% |
| Random Forest | 86.7% ± 0.2% | 84.7% ± 0.3% | 85.5% ± 0.2% |

### Interpretation and justification

In this comparison, the CNN has the highest reported mean macro accuracy and macro F1 among the three individual classifiers. The LSTM is close, while the Random Forest has a lower mean score on the reported test setup. These results make the **1D CNN a defensible leading individual choice** for the presentation: it gives the strongest average class-balanced result in this table. The application nevertheless provides a choice between the classifiers, so the result does not mean the other algorithms were removed. The evidence also does not establish that the CNN is universally best, statistically significantly better in every setting, or the fastest model on the demonstration hardware.

The overall result conceals variation between stroke types. The CNN's reported F1 is **80.1% ± 1.1% for drops**, compared with **97.5% ± 0.6% for serves**. The report also identifies drops being predicted as smashes in 17% of the relevant CNN cases. This is useful for interpreting the confusion matrix: even a model with a strong aggregate score can confuse specific movements. [Per-class results and confusion matrices](docs/results/strokes.md), [CNN confusion matrix image](docs/results/strokes_confusion_cnn.png).

The project also evaluated a **pose-only ablation**, where the CNN did not receive shuttle trajectory features. Its macro accuracy was **77.5% ± 0.7%**, compared with **91.2% ± 0.6%** for the pose-and-shuttle CNN in the reported experiment. This supports the explanation that shuttle movement contributes useful information in this dataset and setup. It does not prove that the same improvement will occur on a new camera or when shuttle tracking is unreliable. [Ablation results](docs/results/strokes.md).

### Limits and other reported evaluations

The model-only test split had already been read multiple times during development, so the results should be treated as estimates rather than as a pristine one-time held-out comparison. The later [match-grouped cross-validation report](docs/results/strokes_cv.md) evaluates additional configurations using a different procedure and records a fourth test-split read, including a revised Random Forest result. Its numbers should not be mixed into the November 16 table without explaining the changed setup.

A separate [context and ensemble report](docs/results/stroke_context.md) evaluates shipped weights with additional rally and court information. It reports 93.4% macro accuracy for the CNN and 93.8% for an ensemble with context. These are separate, single-configuration results, not the three-seed model-only means in the table. The ensemble combines model probabilities; context adjusts probabilities using information such as rally position and player location. They show another possible system configuration, not a directly interchangeable replacement for the model-only comparison.

## 6. Programming Language & Implementation — 0:45

ShuttleSense uses **Dart with Flutter** for its client and **Python** for its backend. Flutter supports a shared application codebase across the project's target device types, giving users screens for connecting, choosing a video, calibrating and viewing results. Python is suitable for the backend because the project can use its existing computer-vision and machine-learning ecosystem for video processing, model inference and numerical analysis. [Technology stack](docs/TECH_STACK.md).

| Technology | Contribution to the application |
| --- | --- |
| **Flutter and Dart** | Build the interface and display video, controls and analysis results across supported platforms. |
| **FastAPI and Python** | Expose backend endpoints, validate requests and coordinate analysis jobs. |
| **OpenCV** | Reads and processes video frames and supports drawing and geometric operations such as court mapping. |
| **NumPy** | Represents numerical data such as positions, trajectories and feature arrays, and supports efficient calculations. |
| **PyTorch and ONNX Runtime** | Support the relevant neural-model training or inference paths; ONNX Runtime is used for the detection and pose stack. |
| **scikit-learn** | Supports Random Forest training; the project documents a separate NumPy-based inference implementation for saved trees. |
| **HTTP/REST and WebSocket** | Connect the client and backend for recorded-video setup/results and streaming communication respectively. |

A structured clip record and arrays of frame-level information give the stages a common way to exchange results. Time windows preserve the order of movement around a hit, which is important because a stroke is a sequence of actions rather than a single still image. The shared record also lets the rendering and summary stages use earlier analysis without having to repeat every calculation. [Architecture and shared record](README.md#how-it-works), [backend stack](docs/TECH_STACK.md#backend-backend).

The language choice should be justified by these responsibilities: Flutter supports the user-facing application, while Python and its libraries support processing and machine learning. The choice itself does not guarantee accuracy or performance; those still have to be measured.

## 7. Data Preprocessing, Processing Pipeline & Output Evaluation — 1:00

This section explains how ShuttleSense turns video into an analysis and how the **CPU, GPU and rendering stages** contribute. The complete explanation below provides background; the presentation can summarize the flow and the distinction between model inference and video export in one minute.

### 1. Input, decoding and calibration

The input is a recorded video or camera frames. The backend reads the video into individual frames, and preprocessing prepares the images and numerical data in the form required by each model. This includes resizing and converting images, preparing player crops for pose estimation, and organizing the shuttle's temporal input. These operations involve CPU work and memory transfers; they are not all automatically performed on the GPU simply because CUDA is available. [Pipeline workflow](README.md#how-it-works), [pose profiling](docs/results/watch_phase3_pose_profile.md), [tracking audit](docs/results/watch_phase4_tracknet_audit.md).

Court calibration uses marked court corners to calculate a **homography**, a mapping between positions in the video image and an approximate top-down court plane. It helps the system relate player and shuttle positions to the court. Its reliability depends on accurate corners and the camera view; a single camera does not recover the complete three-dimensional flight of the shuttle. The Watch interface notes that player detection is disabled without calibration; court-dependent outputs also require suitable calibration. [Watch controls](app/lib/features/watch/watch_screen.dart), [project methods](docs/PRD.md).

### 2. Model inference: where CUDA and the GPU fit

The backend can use an NVIDIA GPU for supported model computation when CUDA, the required libraries, model weights and a compatible device are available. **CUDA** is NVIDIA's computing platform for running supported operations on its GPUs. It is used here to accelerate suitable numerical work in machine-learning inference; it does not mean that every stage, operation or video frame is processed exclusively by the GPU.

- **Shuttle tracking:** TrackNetV3 processes a temporal sequence of frames to estimate shuttle positions. Its PyTorch inference can run on the configured CUDA device; preprocessing, decoding the predictions and transferring results still contribute work outside the GPU model call. [Tracking implementation](backend/shuttlesense/tracking/ensemble.py), [tracking audit](docs/results/watch_phase4_tracknet_audit.md).
- **Player detection and pose:** the rtmlib/ONNX Runtime path detects people and estimates body keypoints. ONNX Runtime uses an **execution provider** to run supported model operations on an available backend. In the documented Watch diagnostic configuration, the detector used CUDA and the pose model used TensorRT RTX, with CUDA and CPU fallback paths available. Actual providers and node placement depend on the installation and session, so the selected device or presence of a GPU alone does not prove that every operation ran on the GPU. [Pose profile](docs/results/watch_phase3_pose_profile.md), [validation report](docs/results/watch_phase7_validation_report.md).
- **Stroke classification:** the CNN and LSTM are PyTorch models that can run on the configured device using features around a hit. The Random Forest's saved-tree inference uses NumPy, so it should not be presented as a CUDA neural model. The ensemble combines classifier predictions and inherits the requirements of its component models. [Classification code](backend/shuttlesense/strokes/classify.py), [technology stack](docs/TECH_STACK.md).

In the Watch configuration, independent shuttle and player/pose perception can be coordinated concurrently on CUDA, while the CPU path is configured to run sequentially by default. Concurrency can help utilize resources, but it is not a promise that every GPU workload runs simultaneously or that the full application is always faster. Copies between CPU memory and GPU memory, synchronization, initialization and contention also affect the total time. The current candidate filtering and pose batch size are experimental and have not passed the project's held-out accuracy promotion gate. [Performance roadmap](SHUTTLESENSE_PERFORMANCE_ROADMAP.md), [integration validation](docs/results/watch_phase7_validation_report.md).

A CPU execution path also exists when GPU acceleration is not selected or available, subject to the installed dependencies and actual configuration. The documented short CPU/CUDA/RTX smoke checks are not a complete validation of every CPU fallback or full user workflow.

### 3. From detections to stroke and match analysis

After inference, the system converts estimated shuttle positions and body keypoints into a form used by later stages. The project describes rule-based hit detection using a change in shuttle direction near a player's wrist. Around a likely hit, pose and shuttle features are organized into a time window, normalized as required by the trained model, and passed to the selected stroke classifier. The BST training features use 30-frame windows, while the CNN configuration records a 30 fps window rate; the source clip itself need not be 30 fps. [CNN configuration](backend/configs/stroke_cnn.yaml), [project methods](docs/PRD.md).

Downstream logic can use the resulting events and court coordinates to calculate stroke counts, map positions, estimate speed, and derive rally or assisted referee information. Pose-based rules can provide heuristic form cues. Any missing or incorrect shuttle or player detection can influence those later outputs, so classification, scoring and visualization should be interpreted as estimates.

### 4. Rendering, encoding and displaying results

**Rendering** means drawing the available visual annotations onto frames or presenting structured data in the app. The backend's annotated-video path reads source frames and uses the stored analysis record to draw enabled overlays, such as a shuttle trail, player boxes or pose skeletons, court markings and stroke labels. Overlay drawing in the documented export path is CPU work; it is separate from GPU inference. The app then displays available video, timeline, court view and summaries. [Rendering implementation](backend/shuttlesense/render/overlays.py), [export benchmark](docs/results/watch_phase6_export_benchmark.md).

**Encoding** turns the rendered frames into a playable video file. The project's default export uses FFmpeg's **libx264**, a CPU-based H.264 encoder. An optional FFmpeg **h264_nvenc** path uses NVIDIA's hardware video encoder on supported systems; NVENC is distinct from CUDA model inference, and enabling it does not mean overlay drawing moved to the GPU. If NVENC is unavailable at the initial check, the writer can fall back to libx264; where FFmpeg is unavailable, an OpenCV `mp4v` fallback is also documented, with possible browser compatibility limitations. Failures after encoding starts are reported rather than assumed to have produced a valid file. [Video writer](backend/shuttlesense/render/writer.py), [export benchmark](docs/results/watch_phase6_export_benchmark.md).

The project retained libx264 as the default because its limited export comparison did not demonstrate a compelling overall NVENC benefit at comparable quality. For example, in one 525-frame comparison the reported means were **2.816 seconds for libx264 and 2.819 seconds for NVENC**; the experiment used two sections of one recording and different quality settings, so it is not a universal speed comparison. Model inference speed, overlay drawing time and encoding time are separate measurements. [Export benchmark](docs/results/watch_phase6_export_benchmark.md).

### 5. Output evaluation and interpretation

A **confusion matrix** compares reference stroke labels with predicted labels. Matching cells represent correct classifications; off-diagonal cells show mistakes, such as a drop labeled as a smash. It explains which classes are confused rather than reducing performance to one number. The [CNN confusion matrix](docs/results/strokes_confusion_cnn.png) accompanies the [per-class results](docs/results/strokes.md); its displayed axes and normalization determine how individual cells should be read.

The reported classifier scores evaluate stroke predictions on pre-extracted broadcast-match features. They do not establish shuttle tracking accuracy, hit detection accuracy, rendering speed, live latency or end-to-end performance on a phone video. Those require separate labeled data or timed measurements. The [November 20 integration report](docs/results/watch_phase7_validation_report.md) records short model-backed smoke runs but says that combined promotion and held-out player, shuttle and event accuracy were not established. A smoke run shows that a particular path executed under its stated conditions, not that the complete workflow is validated.

**Concise presentation explanation:** "ShuttleSense first reads and prepares the video, then uses tracking and pose models to estimate the shuttle and players. Supported model inference can run on an NVIDIA GPU using CUDA, while the CPU still handles work such as preparation, coordination and drawing overlays. The selected stroke classifier analyzes movement around likely hits. Finally, the system displays the results and can encode an annotated video; CPU-based libx264 is the default, with NVIDIA hardware encoding available as an option. We evaluate stroke labels with metrics and a confusion matrix, while treating end-to-end performance as a separate measurement."

## 8. Application Demonstration & Conclusion — 1:30

### Demonstration purpose and setup

The demonstration shows the difference between **analyzing a recorded rally while watching it** and **analyzing camera frames during a live session**. Both use backend processing to estimate shuttle and player movement, detect likely hits and produce available stroke or match information. The audience should see how each choice works and understand that the displayed observations are estimates.

For Watch & Analyze, prepare a short recorded rally, a connected compatible backend and a configured court. For Go live, prepare a camera pointed at a court, camera permission and a compatible backend. A fixed, elevated view behind the baseline with the whole court visible is the setup recommended by the app. Because the overall demonstration has only 90 seconds and live processing depends on the camera, connection and models, a clearly labeled recording of a previous live session or an already saved result can be used if needed. The recorded demonstration must not be described as a live session occurring at that moment. [Watch controls](app/lib/features/watch/watch_screen.dart), [live setup](app/lib/features/live/live_screen.dart), [validation report](docs/results/watch_phase7_validation_report.md).

### Demonstration sequence: Watch & Analyze and Go live

| Time | What to show | Explanation and connection to the system |
| --- | --- | --- |
| **0:00-0:10** | Show the two choices, **Watch & Analyze** and **Go live**, on the mode chooser. | Watch uses a recorded video; Go live uses camera frames from the current session. Both rely on a connected backend. |
| **0:10-0:35** | Open a prepared **Watch & Analyze** session. Show the selected recording, match format and court calibration, then briefly show playback and an available analysis output. | Explain that Real time plays while analysis runs in the background, whereas Analyze every frame waits for normalized frames. Identify which option the demonstration actually uses; do not imply every original frame is analyzed. |
| **0:35-1:00** | Open **Go live** and show the prepared camera view, match setup and court calibration. Start or show an actual running session if ready; otherwise show a clearly labeled prior recording or saved result. | Camera frames are sent to the backend, which can return detected events and overlays. If visible and supported, point out the separate stroke-model selector and identify the chosen model. |
| **1:00-1:20** | Point to an actual visible trajectory, pose, stroke entry or other result from the demonstrated session. | Connect the output to the pipeline: tracking and pose estimate movement, and a classifier assigns a stroke label around a likely hit. Explain an actual visible output as an estimate, not ground truth. |
| **1:20-1:30** | Give the conclusion and limitation. | The CNN led the reported individual-model comparison on broadcast-derived features; that result does not establish phone-camera or complete-system accuracy. |

If a displayed event is labeled **smash**, the system has estimated that a detected hit and its surrounding pose-and-shuttle features resemble that class. The overlay and label can support review, but a missed shuttle, occluded player or inaccurate calibration can change the result. A displayed speed is an approximation, and an automated line call is not an official decision. Discuss only outputs actually present in the shown mode. [Workflow](README.md#how-it-works), [limitations](README.md#limitations).

A prepared result or recorded live session is a fallback, not evidence that the on-stage camera or backend completed a live run. If footage, analysis mode or classifier differs from what is selected on screen, identify that difference explicitly. Watch's experimental optimizations and the wider integrated application remain subject to the validation limits documented in the [performance roadmap](SHUTTLESENSE_PERFORMANCE_ROADMAP.md) and [integration report](docs/results/watch_phase7_validation_report.md).

### Conclusion

ShuttleSense brings shuttle tracking, player pose estimation, stroke classification and result visualization together to support badminton video review. On the documented broadcast-derived BST test features, the 1D CNN was the strongest individual classifier in the November 16 comparison, with **91.2% ± 0.6% macro accuracy** across three seeds. This result supports the classifier's potential under those conditions, while repeated test-set use and the difference between broadcast footage and new phone footage limit the claim.

Further evaluation on independently labeled phone and doubles footage, along with end-to-end tracking, hit detection and device-latency measurements, would show more clearly how well the application performs in the environments for which it is intended. The existing system should be understood as an assistive analysis tool whose outputs benefit from human review.

---

## Sources

- [ShuttleSense README: system workflow, models, evaluation and limitations](README.md)
- [Project requirements, objectives and users](docs/PRD.md)
- [Stroke classifier results, methodology and confusion matrices](docs/results/strokes.md)
- [Match-grouped cross-validation and later test read](docs/results/strokes_cv.md)
- [Context and ensemble evaluation](docs/results/stroke_context.md)
- [Dataset statistics for the separate team-created split](docs/results/dataset.md)
- [Stroke-model development and pretrained-model research](docs/phases/phase-11-stroke-models.md)
- [Technology stack](docs/TECH_STACK.md), [analysis modes](app/lib/features/mode/mode_screen.dart), [live setup](app/lib/features/live/live_screen.dart), [Watch controls](app/lib/features/watch/watch_screen.dart), and [integration validation report](docs/results/watch_phase7_validation_report.md)
- [ShuttleSet paper](https://arxiv.org/abs/2306.04948), [BST feature source](https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer), and [TrackNetV3 project](https://github.com/qaz812345/TrackNetV3)
