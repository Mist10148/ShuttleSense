# Dataset statistics

## ShuttleSet annotations by split

Counted straight from the ShuttleSet annotation CSVs with the T3.3 label mapping and the committed match split (`backend/configs/splits.json`, made with `scripts/make_splits.py --from-annotations`, seed 42). Measured on 2026-10-30.

| Class | Train (31 matches) | Val (6) | Test (7) | Total |
| --- | ---: | ---: | ---: | ---: |
| net_shot | 8,233 | 1,674 | 1,886 | 11,793 |
| lift | 5,937 | 1,227 | 1,393 | 8,557 |
| smash | 2,942 | 620 | 672 | 4,234 |
| drop | 2,445 | 496 | 559 | 3,500 |
| clear | 2,045 | 408 | 469 | 2,922 |
| serve | 1,701 | 312 | 411 | 2,424 |
| **total** | **23,303** | **4,737** | **5,390** | **33,430** |

Excluded from training: 3,054 strokes. That is 1,647 drives (平球, 小平球, 後場抽平球, 防守回抽: no matching class) and 1,407 marked unknown (未知球種). With those, the dataset has 36,484 strokes.

Every class has well over 500 training samples, so none needs flagging for T3.8. The classes are imbalanced, though: net_shot has 4.8 times as many as serve. Training uses inverse-frequency class weights (`configs/stroke_cnn.yaml`), and results report macro accuracy and macro F1 next to plain accuracy.

## Extracted clips

After `scripts/extract_clips.py`, run `python scripts/dataset_stats.py`. It rewrites this file with the clip-level tables (pass `--out` to keep the annotation tables below and write the clip counts elsewhere): per class, per split and per player, plus the strokes lost at rally boundaries and in failed extractions.
