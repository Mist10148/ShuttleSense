# Stroke classifier latency

40 hits in a 60 s clip, trained weights from `backend/weights/strokes/`. The time covers building the feature windows and one batched prediction, as the pipeline's strokes stage does.

| Model | Device | Median (s) | Max (s) | First run (s) | Load (s) | File (MB) | Target |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1D CNN | cpu | 0.043 | 0.049 | 0.050 | 0.015 | 0.43 | < 30 s (met) |
| LSTM | cpu | 0.052 | 0.062 | 0.068 | 0.017 | 2.68 | < 30 s (met) |
| Random Forest | cpu | 0.086 | 0.087 | 0.089 | 0.116 | 6.03 | < 30 s (met) |
