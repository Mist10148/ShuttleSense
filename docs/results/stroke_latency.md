# Stroke classifier latency

40 hits in a 60 s clip, model: random init (configs/stroke_cnn.yaml).

| Device | Median (s) | Max (s) | First run (s) | Checkpoint load (s) | Target |
| --- | ---: | ---: | ---: | ---: | --- |
| cpu | 0.017 | 0.018 | 0.106 | - | < 30 s (met) |
