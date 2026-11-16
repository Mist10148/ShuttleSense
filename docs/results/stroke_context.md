# Stroke context and ensemble results

What the rally and court context ([`strokes/context.py`](../../backend/shuttlesense/strokes/context.py)) adds on top of each stroke model, and what the ensemble of the three ([D37](../DECISIONS.md)) gives. Measured on Nov 16, 2026 with `python scripts/fit_stroke_context.py` (run from `backend/`), on the shipped default weights: the Nov 15 1D CNN and the Nov 16 LSTM and Random Forest ([strokes.md](strokes.md)).

## What the context is

The 1D CNN, the LSTM and the Random Forest read one second of pose and shuttle around a hit. The context step then multiplies their class probabilities by how likely four facts are under each class, and renormalises:

- whether the hit opens the rally (only a serve does);
- the time until the opponent's next hit;
- whether the hitter stood in the front zone (within 2.0 m of the net) or the rear zone (more than 4.8 m from it);
- the same for the opponent at the reply.

The likelihoods are counted from the ShuttleSet stroke annotations of the 30 training matches and stored in [`context_table.json`](../../backend/shuttlesense/strokes/context_table.json). A weight of 0.5 on them and a floor of 0.005 were chosen on the validation matches, one setting for all models. A hit with no usable context keeps the model's answer.

The ensemble is the plain mean of the three models' calibrated probabilities; the context is applied to that mean as to any single model.

## Result on the test matches

3,136 test strokes, 3,136 joined to their annotation row. Model only, then with context:

| Model | Accuracy | Macro accuracy |
| --- | ---: | ---: |
| 1D CNN | 92.5% → 94.0% | 91.8% → 93.4% |
| LSTM | 91.4% → 92.8% | 90.7% → 92.3% |
| Random Forest | 86.9% → 90.1% | 85.0% → 89.5% |
| Ensemble | 92.7% → 94.1% | 91.6% → 93.8% |

Without the context the ensemble is not better than the 1D CNN alone on macro accuracy: the forest is weak on drops and pulls the mean down there. With the context it is the best of the four by a small margin.

Recall per class:

| Class | 1D CNN | LSTM | Random Forest | Ensemble |
| --- | ---: | ---: | ---: | ---: |
| smash | 88.9% → 89.2% | 87.6% → 89.4% | 87.8% → 90.9% | 89.6% → 90.5% |
| clear | 91.8% → 94.7% | 92.9% → 94.7% | 86.3% → 87.3% | 92.6% → 94.5% |
| drop | 81.3% → 85.4% | 77.1% → 81.3% | 62.5% → 77.8% | 78.1% → 87.9% |
| net_shot | 93.8% → 95.3% | 93.4% → 94.8% | 94.7% → 95.6% | 95.9% → 96.2% |
| lift | 95.6% → 96.4% | 93.4% → 93.5% | 83.9% → 85.8% | 93.9% → 93.9% |
| serve | 99.3% → 99.7% | 99.7% → 100% | 94.5% → 99.7% | 99.7% → 100% |

The confusions the context was aimed at, as counts of test strokes:

| Confusion | 1D CNN | LSTM | Random Forest | Ensemble |
| --- | ---: | ---: | ---: | ---: |
| drop called smash | 47 → 35 | 58 → 49 | 92 → 44 | 59 → 31 |
| smash called drop | 44 → 44 | 41 → 42 | 28 → 30 | 39 → 36 |
| lift called net shot | 29 → 25 | 47 → 46 | 115 → 104 | 45 → 45 |
| net shot called lift | 39 → 27 | 37 → 22 | 29 → 14 | 26 → 16 |
| clear called lift | 4 → 4 | 3 → 3 | 14 → 10 | 4 → 3 |
| clear called drop | 3 → 7 | 8 → 11 | 8 → 25 | 5 → 13 |

One confusion gets worse: more clears are called drops, most with the Random Forest.

Macro accuracy with one kind of context at a time:

| Context used | 1D CNN | LSTM | Random Forest | Ensemble |
| --- | ---: | ---: | ---: | ---: |
| none | 91.8% | 90.7% | 85.0% | 91.6% |
| rally position only | 92.1% | 90.7% | 85.9% | 91.7% |
| flight time only | 92.7% | 91.3% | 87.2% | 92.7% |
| zones only | 92.9% | 91.5% | 85.5% | 92.8% |
| all | 93.4% | 92.3% | 89.5% | 93.8% |

## What these numbers do not show

- **Not phone footage.** These are broadcast matches. Accuracy on the team's own clips is still unmeasured (T7.2).
- **Perfect hits.** The annotated hit frames, rally starts and court areas stand in for the hit detector, the rally break rule and the court calibration. In the app a missed or false hit changes the flight time and the rally position, so the gain there will be smaller, and a wrong hit can make the context wrong. A reply later than 2.5 s is ignored for that reason.
- **Zones are approximate.** ShuttleSet marks court areas, not metres. The front and rear limits used in the app (2.0 m and 4.8 m from the net) were set from the layout of those areas, not fitted; a player between them counts as neither.
- **Singles only.** ShuttleSet is singles. In doubles only the rally position is used.
- **Live and Watch.** A hit is labelled about half a second after it happens, usually before the reply, so it gets the rally position and the hitter's zone but often not the flight time.
- **The test split has been looked at before.** The stroke models were evaluated on it on Nov 14, Nov 15 and Nov 16 ([strokes.md](strokes.md)). The context settings were chosen on validation only, but read the gain as an estimate.
- **One set of weights.** The default weights only, not the three seeds of [strokes.md](strokes.md).
