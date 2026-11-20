# Stroke models: match-grouped cross-validation (Nov 20, D41)

The BST test split had been read three times before this pass, so every training choice
here was made by cross-validation first (`backend/scripts/cv_strokes.py`):

- The BST train and validation matches are pooled (27,544 windows from 35 matches).
- They are split into 5 folds **by match**: no match has windows both in training and in
  the scored part of a fold.
- Inside each fold, about a tenth of the training matches are held out for early stopping
  and the temperature, so the scored matches are never seen while training.
- Scores are the mean ± std over folds. The networks were screened on the first 3 of the
  5 folds, scored with test-time augmentation (TTA). The plain column is the same
  model scored without it.
- Out-of-fold probabilities are kept (`outputs/cv/*_oof.npz`) and used to fit the
  ensemble.

## Random Forest (5 folds)

| Variant | Macro-F1 | Accuracy | Calibration error (ECE) | Drop called smash |
| --- | --- | --- | --- | --- |
| Shipped settings (summary v2, no calibration) | 85.4% ± 1.6% | 86.1% | 0.105 | 17.4% |
| **Summary v3 (velocity rows) + temperature** | **86.4% ± 1.1%** | **87.5%** | **0.016** | 17.5% |
| v3 + extra-trees, 300 trees | 86.5% ± 1.3% | 87.4% | 0.021 | 18.8% |
| v3, 250 trees, depth 24, leaf 2, 15% features | 86.7% ± 1.1% | – | 0.018 | 17.8% |

Kept: v3 with calibration. The two larger variants are within the spread and give a
bigger file.

## 1D CNN (3 folds)

| Variant | Macro-F1 (TTA) | Plain | ECE | Drop called smash |
| --- | --- | --- | --- | --- |
| **Shipped settings** | **91.3% ± 0.9%** | 90.9% | 0.012 | 10.4% |
| Motion channels (`data.feature_version: 2`) | 90.8% ± 0.7% | 90.7% | 0.010 | 9.1% |
| Motion + scale/joint/shuttle dropout, time-warp 0.1, mixup 0.2 | 89.5% ± 1.1% | 89.3% | 0.011 | 11.5% |
| The same + logit-adjusted loss | 89.7% ± 1.2% | 89.6% | 0.009 | 12.4% |
| Logit-adjusted loss | 90.9% ± 0.9% | 90.7% | 0.010 | 11.4% |
| Mixup 0.2 | 90.7% ± 0.9% | 90.6% | 0.012 | 12.3% |
| Wider (128/256/256 channels, 60 epochs) | 91.7% ± 0.5% | 91.5% | 0.013 | 10.5% |

TTA adds about 0.4 points to every variant, so it is on for uploaded clips.

The wider CNN was trained with seeds 1-3 on the full train split. On the test split it
scored 90.6% ± 0.4% macro accuracy (91.3% with TTA, best seed). The shipped CNN scores
91.8% on the same code, so the shipped CNN was kept.

The heavier augmentation is meant for footage unlike the broadcast training data. This
CV is broadcast only, so it can only show the cost (about 1.5 points), not the benefit.

## LSTM (3 folds)

| Variant | Macro-F1 (TTA) | Plain | ECE |
| --- | --- | --- | --- |
| **Shipped settings** | **90.3% ± 0.5%** | 90.2% | 0.015 |
| Motion channels | 90.5% ± 0.4% | 90.4% | 0.018 |

The gain is within the spread and calibration is worse, so the shipped LSTM was kept.

## Ensemble

Weights were searched in steps of 0.1 for the mean and the weighted geometric mean, on the
16,457 windows that have out-of-fold predictions from all three models.

| Rule | Out-of-fold macro-F1 | NLL | Test macro accuracy, shipped models (plain / TTA) |
| --- | --- | --- | --- |
| Equal-weight mean (D37) | 91.6% | 0.251 | 91.7% / 91.9% |
| **Geometric, CNN 0.5 / LSTM 0.3 / forest 0.2** | **91.8%** | **0.228** | **92.2% / 92.1%** |

These test numbers are before the rally and court context (`strokes/context.py`), which is
applied on top of any model.

## Test split, fourth read

| Model | Macro accuracy | Change |
| --- | --- | --- |
| Random Forest, seeds 1-3 | 85.3% ± 0.2% (macro-F1 86.2%) | +0.6 (was 84.7% ± 0.3%) |
| 1D CNN, LSTM | unchanged weights | – |
| Ensemble, fitted weights | 92.2% | +0.5 over the equal mean |
