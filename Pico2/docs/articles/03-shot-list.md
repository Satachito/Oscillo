# Episode 3 — shot list

Japanese: [03-shot-list.ja.md](03-shot-list.ja.md).

Same piles as episodes 1 and 2. **Screen** is a recording of the **Mac app**;
**Bench** is a camera pointed at hardware; **Already have** is footage or
graphics that exist and do not get re-shot.

**One thing this episode does not do:** show picoLABO's own schematic on
screen. It's linked in the description, but reproducing a manufacturer's
proprietary schematic image in the video itself isn't ours to do — the
"fixed divider → switch → gain stage" beat is a generated card, our own
drawing of the idea, not a screenshot of their document.

Times are the script's section marks, not a promise.

## Screen recordings

Record at the display's native size; trim in the edit.

| # | Shot | Where | Notes |
| --- | --- | --- | --- |
| S1 | The range menu open on CH1: ±30 V, ±6 V, ±1.5 V. | 0:00 cold open | This is the first thing the Mac app shows. Board connected to a battery pack or bench supply, any steady DC in range so the reading isn't just noise. |
| S2 | The Calibrate panel for CH1's ±30 V range, mid-calibration against the four-cell pack. | 2:45 | Show the "known voltage" field being filled and the result landing. |
| S3 | CH1 switched to the ±1.5 V range, the single cell connected. | 2:45 | Just before the ±6 V trick — this shot is "the meter's answer," the next one is "the better answer." |
| S4 | The same single cell read through the already-calibrated ±6 V range — the number the app reports, in close-up. | 2:45 | This is the number the narration quotes as the four-figure read (**[MEASURE]**, expect close to 1.3078 V from the 2026-09-22 bench pass). |
| S5 | Live: CH1's range menu, select ±6 V, watch the reading not move. | 5:45 | This is real — the switch really doesn't close. Do not dress this up or cut around it. Let a few seconds sit after the click so the "nothing happened" reads clearly. |

## Bench shots

Shoot down onto a plain surface, landscape always.

| # | Shot | Used at | Notes |
| --- | --- | --- | --- |
| B1 | Episode 2's mini AFE breadboard, input lead lifted, touching nothing. | 0:00 cold open | Reuse the breadboard if it's still assembled; if it's been taken apart, a quick reassembly of just the input lead area is enough — this shot is on screen for two seconds. |
| B2 | The PL2407AFE, BNC cable connected to a bench supply or battery pack, board powered. | 0:00 cold open / running throughout | The episode's main hero shot of the board. Get this clean once and it covers most of the episode's B-roll needs. |
| B3 | The BNC connector, close-up. | 1:30 | Macro or phone close-focus; doesn't need to be live, just needs to read clearly. |
| B4 | Four AA batteries in a holder, multimeter reading them (~5 V), wired into the board's input. | 2:45 | The meter's display needs to be legible at 1080p — angle it so there's no glare. |
| B5 | A single cell, multimeter reading it, wired into the board's input in place of the four-cell pack. | 2:45 | Swap only the cell, not the wiring — keep the same clip leads so the cut reads as a continuation. |
| B6 | The board's edge test lands — GND / VBUS / +3V3 / −3V3 — multimeter probing +3V3, reading a clean 3.3 V. | 4:30 | This shows the *fixed* state. The narration describes the fault (2.2 V, cold joint) over this shot rather than the shot trying to reproduce it — the fault isn't something to re-break for the camera. |
| B7 | The reflowed VBUS joint at Pico 2 physical pin 40, close-up. | 4:30 | If the joint isn't visually distinct enough to read as "the fix," skip this and stay on B6 with narration carrying the point. |
| B8 | Live: a probe on GPIO3 at the header, and a second probe at the switch IC's own pin, both showing the same clean 0 V / 3.27 V swing. | 5:45 | This is the real diagnostic step, shot as it happens — it's what backs up "the control side is not the problem." Two probe points, so either two clips cut together or a two-channel logic/meter shot if that's easier to frame. |
| B9 | The J1 header, a resistor lead pushed into a socket (contrast with a loose stranded wire not seating). | 7:45 | Show the wire failing to make contact first if that's easy to stage honestly, then the resistor lead working — otherwise just the working case is enough. |

## Already have — do not re-shoot

| Asset | From | Used at |
| --- | --- | --- |
| `card_no_protection.png` | Episode 2 | 0:25 — the "no protection, no attenuation" callback, before cutting to this board's fixed input divider. |

## Cards (generated, not filmed)

Built the same way as episodes 1–2's (`cards.py` / `ep2_cards.py`), not shot
with a camera.

| Card | Content | Used at |
| --- | --- | --- |
| `card_input_chain` | Our own block diagram: fixed divider → range switch → gain stage. **Not** picoLABO's schematic. | 0:25 |
| `card_survives` | ±40 V absolute max, 43 µA / 4.53 V at the divider (labeled "calculated, not measured"), plus the rev A vs. PL2407AFE comparison table. | 1:30 |
| `card_cal_check` | The ±30 V range's gain from the 5.01 V read and the 1.3 V read, side by side, agreeing to **[MEASURE, expect ~0.03%]**. | 3:30 |
| `card_switches` | Four switches in one package, three work / one doesn't; the VBUS-fault timing note, labeled as a working theory, not a confirmed cause. | 6:30 |
| `card_limits` | No isolation · absolute max ≠ working limit · can't read mains. | 7:45 |

## Which board/setup is on the bench when

| Shot | State |
| --- | --- |
| B1 (0:00) | Episode 2's mini AFE, briefly, for contrast only. Not used again. |
| B2 (0:00 onward) | PL2407AFE, powered, BNC in. This is the episode's default state — return to it between other setups. |
| B4 → B5 → S2 → S3 → S4 (2:45) | Four-cell pack, then swapped to a single cell. Keep the same clip leads across the swap so the cut reads clean. |
| B6 / B7 (4:30) | Board already in its fixed, working state — no rework happens on camera. |
| S5 / B8 (5:45) | Current real state: CH1's ±6 V switch does not close. Do not attempt a fix for this episode. |
| B9 (7:45) | J1 header, independent of everything else — shoot whenever convenient. |

## Order to shoot in

1. B2 first — the board powered and connected is the default state for most
   of the episode, and every other bench shot cuts back to it.
2. B1 — episode 2's breadboard, for the cold open contrast. Quick, independent.
3. B3 — the BNC close-up. Independent, no state to set up.
4. B4, then S2 (calibrate ±30 V against the four cells), then B5, then S3
   and S4 (±1.5 V, then the ±6 V-as-ruler read) — this whole block in one
   sitting, since it's one continuous setup with one swap in the middle.
5. B6 and B7 — the fixed test lands and the reflowed joint. No state change
   needed; the board is already correct.
6. S5 and B8 together — the live ±6 V bug and the probe comparison that backs
   it up. Same sitting, since both are about the same fault.
7. B9 last — the J1 header note, whenever there's a spare few minutes.

S1 (the cold-open range menu) can be captured any time the board is powered
and connected — it doesn't depend on any of the above.
