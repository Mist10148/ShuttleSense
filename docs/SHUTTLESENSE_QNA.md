# ShuttleSense Q&A Reference

### How does AI Coach use RAG?

**RAG** means retrieval-augmented generation. ShuttleSense analyzes the video first and saves observations with timestamps. When building feedback, AI Coach retrieves relevant badminton guidance and gives the language model that guidance together with the saved observations. The result is an **Overall Summary**, **Detailed Analysis** with moments to replay, and **Follow-up Questions** grounded in the same session. The provider receives text and structured observations. The report has a rules-based fallback if generation fails. The feedback depends on the quality of the saved observations and can still be wrong. [AI Coach workflow](AI_COACH.md)

### What three data structures does ShuttleSense use?

The first item covers two views of the same model input.

| Structure | What it does |
| --- | --- |
| **1. Temporal feature arrays and multidimensional tensors** | One stroke is an ordered array of 30 frames with 39 features per frame in the combined model. The features describe body joints and shuttle movement. The CNN receives a batch of those windows as a tensor shaped `[batch, features, frames]`. |
| **2. Frame-indexed records** | Each video frame has a numbered record that can hold detections and court positions. Hits also reference frame numbers, so the app can seek to the corresponding moment and draw the right overlay. |
| **3. 2D occupancy grids** | The court is divided into 0.25 m cells. Detected player time is accumulated around those cells and visualized as a heatmap. Brighter or stronger shading represents more time in that area. |

[Feature layout](DATA_FORMAT.md), [record schema](../backend/shuttlesense/schema.py), [occupancy grid](../backend/shuttlesense/analytics/heatmap.py)

### What is the CNN’s time and space complexity?

For one stroke window with **T frames**, the 1D CNN takes **O(T) inference time** and **O(T) working memory** when layer sizes, kernel widths, and feature count are fixed. Each convolution slides a fixed-size filter along the window, and its intermediate feature maps grow with the window length. The model weights use **O(1)** space with respect to T. The classifier uses 30-frame windows in practice. These bounds cover one CNN prediction. [CNN implementation](../backend/shuttlesense/strokes/model.py), [classifier inference](../backend/shuttlesense/strokes/classify.py)

### Where does CUDA help, and how is the video rendered?

**CUDA accelerates supported model inference**, such as shuttle tracking, on compatible NVIDIA hardware. The export pipeline reads the video, draws overlays on the CPU, and sends each annotated frame to FFmpeg. The normal output is **H.264 in an MP4**. FFmpeg uses CPU **`libx264`** by default. The optional **`h264_nvenc`** uses NVIDIA’s dedicated hardware encoder when supported. If the NVENC preflight fails, FFmpeg uses `libx264`. [Processing roles](IMRAD_DISCUSSION.md#43-computational-and-implementation-considerations), [export writer](../backend/shuttlesense/render/writer.py)

**Rendering limitation.** Hardware encoding accelerates the encoding step. Frame reading, CPU overlay drawing, and moving frames through the pipeline can still limit export speed. In one 525-frame, 720p test, export took about **2.82 s with either encoder**, so that trial showed no meaningful NVENC speedup. Those timings cover export after analysis. [Export benchmark](results/watch_phase6_export_benchmark.md)

### How do court calibration and player selection work?

- **Court calibration — homography.** We confirm four court corners, found automatically or marked manually. The app uses them to turn the angled camera view into a flat court map. A fixed camera and accurate corner placement keep the map aligned. [Court calibration code](../backend/shuttlesense/court/homography.py)
- **Player tracking in Watch & Analyze — track association.** Watch assigns detected players to near- or far-side slots. It uses where each player was, how they moved, and appearance cues to match new detections to the same slots. If someone is hidden or two players overlap, the match can become uncertain. [Watch player tracker](../backend/shuttlesense/pose/player_tracker.py)
- **Manual player selection — intersection over union (IoU).** The manual tap is in **AI Coach**. In its court-based workflow, the app compares the box you picked with the boxes from Watch’s tracker. The amount of overlap helps link your selection to a single tracked player. [Player box matching](../backend/shuttlesense/stream/perception.py)
