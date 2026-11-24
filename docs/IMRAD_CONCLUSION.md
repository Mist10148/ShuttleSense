## V. CONCLUSION AND RECOMMENDATIONS

### 5.1 Conclusion

This study developed ShuttleSense to analyze recorded and live badminton footage, compared three stroke classifiers, and evaluated the contribution of shuttle movement features. In the three-seed comparison on ShuttleSet broadcast singles, the **1D CNN led the LSTM and Random Forest** with **91.9% overall accuracy, 91.2% macro accuracy, and 91.0% macro F1**. It also had the smallest checkpoint and lowest median CPU stroke-stage time in the benchmark, supporting its selection as the default classifier. Adding shuttle features raised CNN macro accuracy from **77.5% to 91.2%**, although drops were still frequently confused with smashes. [Algorithm results and ablation](IMRAD_RESULTS.md), [CPU benchmark](results/stroke_latency.md)

ShuttleSense integrates player and shuttle tracking, stroke timelines, court maps, occupancy heatmaps, and annotated video export into a workflow for reviewing matches and practice. AI Coach adds summaries, timestamped feedback, and follow-up questions based on saved observations and retrieved badminton guidance. The study measured classifier performance on broadcast-derived stroke windows and demonstrated system functionality. Accuracy on phone footage, end-to-end live performance on real courts, and the quality of coaching advice still require validation. [System outputs](IMRAD_RESULTS.md#34-system-implementation-and-demonstration-results), [study limitations](IMRAD_DISCUSSION.md#45-limitations-of-the-study)

### 5.2 Recommendations

1. **Expand real-world testing.** Collect consented, labelled phone recordings and live sessions across venues, camera angles, lighting, and singles and doubles play. Hold out entire matches and venues for final testing.
2. **Improve model generalization.** Prioritize drop–smash confusion and test robustness when the player or shuttle is obscured. Measure stroke accuracy using both annotated and automatically detected hit times to quantify how detection errors affect classification.
3. **Optimize processing and export.** Profile decoding, inference, overlay drawing, and encoding separately across CPU and GPU configurations. Compare live latency, dropped frames, analysis-to-save time, and export quality on representative clips before changing defaults.
4. **Validate AI Coach feedback.** Ask badminton coaches to review recommendations and cited timestamps on real practice clips. Use their assessments to improve retrieval and make insufficient evidence visible in the report.
5. **Extend review tools.** Make uncertain detections and tracking gaps easier to inspect, and add side-by-side replay of comparable attempts so players and coaches can track changes across sessions.
