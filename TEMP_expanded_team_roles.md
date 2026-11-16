# 4. Team Roles

The following responsibilities reflect the assignments supplied by the project team. The application, backend, computer-vision models, and project documentation are developed collaboratively; primary and secondary responsibilities identify each member's main area of focus and supporting contributions.

## Occeña — AI Coach and Performance Optimization Developer

### Primary responsibilities

**AI coach development and session context.** Occeña is primarily responsible for the development of ShuttleSense's AI coach feature and the preparation of the analysis context used by that feature. His work involves organizing information from the shared `ClipRecord`, which serves as the structured record of a processed video or live session. This record brings together available information such as detected hits, classified strokes, rallies, estimated shuttle speed, and feedback associated with particular moments. He works on presenting these outputs in a form that the coaching workflow can use to produce session-specific guidance.

**Coaching summaries and feedback integration.** His responsibilities include structuring session summaries around relevant statistics, recurring performance patterns, and rule-based form feedback. These summaries can identify improvement areas and associate available observations with timestamps or recorded moments, allowing users to return to the relevant part of a video. He also works on connecting the session digest with the coach-chat workflow, so the coach can respond using the information available in the session record. The coaching feature's output remains dependent on the completeness and reliability of the underlying analysis.

### Secondary responsibilities

**Player detection and pretrained-model refinement.** Occeña supports the calibration and refinement of player detection, including the behavior of the pretrained components used for player detection, pose estimation, and shuttle tracking. This work involves examining how model outputs enter the analysis pipeline and how detection and tracking behavior affects subsequent stages such as hit identification, feedback, and visualization. He collaborates with the machine-learning team when reviewing the configuration and integration of these components.

**Analysis and rendering performance.** He also works on algorithms and processing workflows intended to reduce the time needed to analyze footage and generate an annotated output video. This responsibility covers the relationship between computer-vision processing, downstream analysis, video overlays, and output rendering. Performance improvements should be assessed through appropriate timing measurements; the assignment itself does not establish a particular speedup.

## Delariman — Player Heatmap Calibration and UI Developer

### Primary responsibilities

**Player-coverage heatmap calibration.** Delariman is primarily responsible for calibrating and refining the player-coverage heatmap, a visualization of the areas of the court occupied by tracked players during a session. His work involves reviewing how recorded player positions are accumulated across video frames and represented as a spatial distribution on the court. This helps make the visualization useful for interpreting court coverage and player positioning.

**Court mapping and minimap visualization.** His responsibilities also include reviewing the relationship between detected player positions, the calibrated court, and the top-down minimap. ShuttleSense uses four court corners and a homography to map eligible positions from the video plane to court coordinates; the heatmap depends on that mapping as well as the quality of the player-position data. He helps assess whether the resulting coverage display is spatially interpretable and readable. This player-coverage heatmap is separate from the neural-network output heatmaps used in shuttlecock tracking.

### Secondary responsibilities

**Flutter user-interface development.** Delariman also contributes to the application's main user interface using Flutter. His supporting work includes screen layouts, visual components, and the presentation of analysis results, particularly where court visualizations and user controls must fit into the wider application. He coordinates these contributions with the lead UI/UX and front-end developer to maintain consistent navigation and visual presentation.

## Aristoki — Full-Stack and Machine Learning Developer

### Primary responsibilities

**Technology stack and system integration.** Aristoki contributes across the application and backend as a full-stack developer, with responsibility for setting up and integrating the project's technology stack, pretrained models, and data workflows. This includes the relationship between the Flutter client, the Python/FastAPI backend, and the computer-vision pipeline. His work supports the flow of user requests, processing status, and structured analysis results between application interfaces and backend services.

**Player detection, pose estimation, and data workflows.** He works on the configuration, calibration, integration, and validation of machine-learning components, especially those involved in player detection and pose estimation. In the documented pipeline, player detection and pose estimation provide bounding boxes and body keypoints that feed subsequent tracking, hit analysis, and form-feedback stages. His responsibilities also include relevant data preparation and training activities where applicable, alongside the use of pretrained models. These activities do not imply that all pretrained models were developed or trained from scratch by the project team.

**Stroke-classification model evaluation.** Aristoki is also involved in testing and evaluating alternative algorithmic approaches for stroke classification. The approaches documented by the project include a one-dimensional convolutional neural network (1D CNN), a random forest, and a long short-term memory (LSTM) network. His role includes examining available evaluation evidence to help determine an appropriate approach for classifying badminton strokes from pose and shuttle-related features. Model comparisons must be interpreted in the context of the dataset, split, and evaluation conditions used; they do not by themselves establish performance on the team's own match footage.

### Secondary responsibilities

**Cross-component testing and collaboration.** He collaborates with other team members to investigate issues involving model outputs, pipeline integration, backend processing, and their presentation in the application. This includes supporting the identification of inconsistencies between components and helping the team assess whether the overall workflow behaves as intended.

## Limpin — Lead UI/UX Designer and Front-End Developer

### Primary responsibilities

**UI/UX design and Flutter front-end structure.** Limpin leads the design of the application's user interface and user experience and is primarily responsible for establishing the Flutter front end. Her work covers the visual organization of screens, navigation, layout, interaction patterns, and reusable interface components. She considers how the same application can present its features across supported phone, tablet, desktop, and web layouts while maintaining a coherent visual hierarchy.

**Application workflows and results presentation.** Her responsibilities include designing and implementing user-facing workflows for connecting to the backend, selecting and uploading footage, monitoring processing, and reviewing analysis results. She also helps organize the presentation of features such as video playback, timelines, court views, session summaries, and coaching controls. The goal is to make the system's technical outputs understandable and accessible through the application's interface.

### Secondary responsibilities

**Front-end coordination and usability refinement.** Limpin coordinates with Delariman and Agtoto on their supporting interface work, helping maintain consistency in layouts, components, and interactions. She also participates in reviewing and refining the usability of application screens with the rest of the team as implementation and testing progress.

## Segocio — Project Documentation Lead and CNN Calibration Support

### Primary responsibilities

**Technical and academic documentation.** Segocio is primarily responsible for preparing and maintaining documentation for the project as a whole. His work covers the project's objectives and scope, system architecture, technology stack, setup and usage workflows, development progress, and supporting technical details. He translates the operation of the Flutter application, backend services, and computer-vision pipeline into descriptions suitable for academic and technical readers.

**Progress, evaluation, and limitations.** His documentation responsibilities also include recording the context of available tests and evaluations, describing known limitations, and keeping progress statements consistent with the evidence available to the team. This includes distinguishing implemented functionality from features that still require validation on real footage or devices, and documenting the conditions and qualifications associated with reported results.

### Secondary responsibilities

**Pretrained CNN calibration support.** Segocio assists the machine-learning team with the configuration, calibration, and evaluation of pretrained CNN-related components. In this supporting role, he helps review observed model behavior within the relevant detection or classification workflow and communicates issues or findings to the team. The specific model adjustments and experiments should be identified only when confirmed.

## Agtoto — Model Calibration Support and UI Developer

### Primary responsibilities

**Pretrained-model calibration and validation support.** Agtoto primarily supports the configuration, calibration, and validation of pretrained model components in collaboration with Segocio and the machine-learning team. His work includes helping review how model outputs behave within the analysis pipeline and identifying observations or inconsistencies that may need further investigation. This contribution supports the team's broader effort to integrate and evaluate computer-vision components against the project's intended workflows.

**Model integration review.** He assists with examining how configured model components interact with other analysis stages and helps communicate issues encountered during review or testing. The particular models, parameter adjustments, and experimental results remain subject to confirmation and should not be attributed to him without supporting information.

### Secondary responsibilities

**Flutter interface support.** Agtoto also assists with the implementation and refinement of application screens and visual components in Flutter. He coordinates with Limpin and the front-end team so that supporting changes fit the application's established layout, navigation, and interaction patterns.
