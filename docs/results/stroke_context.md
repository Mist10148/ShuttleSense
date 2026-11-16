# Stroke context results

What the rally and court context ([`strokes/context.py`](../../backend/shuttlesense/strokes/context.py)) adds on top of each of the three stroke models. Measured on Nov 16, 2026 with `python scripts/fit_stroke_context.py` (run from `backend/`), on the shipped default weights.

## What the context is

The 1D CNN, the LSTM and the Random Forest read one second of pose and shuttle around a hit. The context step then multiplies their class probabilities by how likely four facts are under each class, and renormalises:

- whether the hit opens the rally (only a serve does);
- the time until the opponent's next hit;
- whether the hitter stood in the front zone (within 2.0 m of the net) or the rear zone (more than 4.8 m from it);
- the same for the opponent at the reply.

The likelihoods are counted from the ShuttleSet stroke annotations of the 30 training matches and stored in [`context_table.json`](../../backend/shuttlesense/strokes/context_table.json). A weight of 0.5 on them and a floor of 0.005 were chosen on the validation matches, one setting for all three models. A hit with no usable context keeps the model's answer.

## Result on the test matches

3,136 test strokes, every one joined to its annotation row. Model only, then with context:

| Model | Accuracy | Macro accuracy |
| --- | ---: | ---: |
| 1D CNN | 92.5% → 94.0% | 91.8% → 93.4% |
| LSTM | 90.3% → 92.1% | 89.1% → 91.2% |
| Random Forest | 86.1% → 89.8% | 84.3% → 89.4% |

Recall per class:

| Class | 1D CNN | LSTM | Random Forest |
| --- | ---: | ---: | ---: |
| smash | 88.9% → 89.2% | 87.4% → 88.7% | 88.9% → 90.7% |
| clear | 91.8% → 94.7% | 90.2% → 91.6% | 84.2% → 85.2% |
| drop | 81.3% → 85.4% | 74.0% → 80.0% | 60.3% → 81.0% |
| net_shot | 93.8% → 95.3% | 92.9% → 94.9% | 93.6% → 95.1% |
| lift | 95.6% → 96.4% | 92.7% → 93.2% | 82.8% → 84.4% |
| serve | 99.3% → 99.7% | 97.6% → 98.6% | 95.9% → 100% |

The confusions the context was aimed at, as counts of test strokes:

| Confusion | 1D CNN | LSTM | Random Forest |
| --- | ---: | ---: | ---: |
| drop called smash | 47 → 35 | 68 → 50 | 98 → 38 |
| net shot called lift | 39 → 27 | 42 → 26 | 40 → 22 |
| lift called net shot | 29 → 25 | 54 → 50 | 123 → 113 |
| smash called drop | 44 → 44 | 44 → 42 | 31 → 31 |
| clear called drop | 3 → 7 | 9 → 16 | 13 → 35 |

One confusion gets worse: more clears are called drops, most with the Random Forest.

Macro accuracy with one kind of context at a time:

| Context used | 1D CNN | LSTM | Random Forest |
| --- | ---: | ---: | ---: |
| none | 91.8% | 89.1% | 84.3% |
| rally position only | 92.1% | 89.5% | 85.0% |
| flight time only | 92.7% | 90.2% | 87.2% |
| zones only | 92.9% | 89.9% | 85.2% |
| all | 93.4% | 91.2% | 89.4% |

## What these numbers do not show

- **Not phone footage.** These are broadcast matches. Accuracy on the team's own clips is still unmeasured (T7.2).
- **Perfect hits.** The annotated hit frames, rally starts and court areas stand in for the hit detector, the rally break rule and the court calibration. In the app a missed or false hit changes the flight time and the rally position, so the gain there will be smaller, and a wrong hit can make the context wrong. A reply later than 2.5 s is ignored for that reason.
- **Zones are approximate.** ShuttleSet marks court areas, not metres. The front and rear limits used in the app (2.0 m and 4.8 m from the net) were set from the layout of those areas, not fitted; a player between them counts as neither.
- **Singles only.** ShuttleSet is singles. In doubles only the rally position is used.
- **Live.** A live hit is labelled about half a second after it happens, usually before the reply, so it gets the rally position and the hitter's zone but often not the flight time.
- **The test split has been looked at before.** The stroke models were evaluated on it on Nov 14 and Nov 15 ([strokes.md](strokes.md)). The context settings were chosen on validation only and the test split was scored once with them, but read the gain as an estimate.
- **One set of weights.** The default weights only, not the three seeds of [strokes.md](strokes.md).
