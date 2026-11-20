# Reading ShuttleSense results

## What the numbers mean
ShuttleSense measures one recorded session from a single camera. Hits are detected from the shuttle track, strokes are classified by a model with a confidence, speeds are 2D estimates in km/h, and form feedback comes from 2D pose rules. Treat all of them as approximate. Compare your own sessions with each other rather than with numbers measured by other systems.

## Form feedback rules
Each classified hit gets pass or fail results for the rules of its stroke class: `contact_above_head` and `elbow_extension` for smashes and clears, `contact_above_shoulder` and `short_follow_through` for drops, `lunge_knee_bend` for net shots and lifts, `racket_arm_forward` for net shots, `wrist_below_shoulder` for lifts, and `contact_below_waist` and `stable_feet` for serves. A rule is skipped when the joints it needs are not visible clearly enough. Camera angle affects 2D angles, so a single fail is not meaningful; a repeated pattern is.

## Session notes and top fixes
Session notes report a rule that failed on at least two strokes and on at least half of the strokes it was checked on, plus rallies a player ended with a shot called out. The top fixes are the notes ranked by how often and how important they are. Start with the first top fix.

## Line calls and score
Line calls come with a margin in centimetres from the line and a confidence. Calls marked UNCERTAIN are not used to decide a rally until a player confirms or overrides them. The score follows the referee stage and any manual decisions the players entered.

## Tracking progress across sessions
To see progress, compare the pass rate of your top-fix rule, the stroke mix, the number of rallies ended by your own errors, and the share of rallies won across sessions recorded from a similar camera position. One session is a snapshot; a trend over several sessions is more reliable.
