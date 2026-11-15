# Stroke classifier latency

40 hits in a 60 s clip, trained weights from `backend/weights/strokes/`. The time covers building the feature windows and one batched prediction, as the pipeline's strokes stage does.

| Model | Device | Median (s) | Max (s) | First run (s) | Load (s) | File (MB) | Target |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 1D CNN | cpu | 0.034 | 0.048 | 0.125 | 0.071 | 0.43 | < 30 s (met) |
| LSTM | cpu | 0.041 | 0.045 | 0.090 | 0.015 | 2.68 | < 30 s (met) |
| Random Forest | cpu | 0.052 | 0.063 | 0.055 | 0.293 | 16.40 | < 30 s (met) |
