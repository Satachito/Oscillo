# Episode 2 — shot list

Japanese: [02-shot-list.ja.md](02-shot-list.ja.md).

Same two piles as episode 1. **Screen** is a recording of the **Mac app**;
**Bench** is a camera pointed at hardware. A third pile is new this time:
**Already have** — footage or graphics that exist and do not get re-shot.

Times are the script's section marks, not a promise.

## Screen recordings

Record at the display's native size and do not resize the window afterwards.
Record each one long; trim in the edit. See episode 1's shot list for the
recording setup (⇧⌘5, Record Selected Portion, Remember Last Selection) — it
is unchanged.

| # | Shot | Where | Notes |
| --- | --- | --- | --- |
| S1 | CH2 running, a 1 kHz tone from the Mac mini's headphone jack, sitting on the dotted mid-rail line. Hold three seconds before the first word. | 0:00 cold open | This is the first frame of the video. 100 Ω across the plug, −18 dB on the display — the shoot's fixed condition (see production notes). |
| S2 | Both channels' readings live at once: the 100 kΩ/100 kΩ divider read through the follower and straight to a pin — Mean, AC RMS, Peak to peak, both columns on screen together. | 2:15 | **Shot 2026-09-22, kept.** Mean came out equal both paths (1.64 V); narration now claims only the noise difference (18.5 mV follower vs 83.0 mV direct, 4.4×). Do not add a mean-difference claim back in against this take. |
| S3 | The LM358 in the socket, driven by the generator's raw carrier: the top of the trace flat. | 3:05 | Same window position as S4 so they cut together. |
| S4 | Swap in the MCP6022. The same sine, now whole — pp readout reads 3.30 V. | 3:05 | Do not move the camera or the window between S3 and S4. |
| S5 | The Mac's headphone jack into CH2: a 1 kHz tone centred on the dotted line, then the shoot's actual music track, the trace dancing around it. | 4:05 | 100 Ω fitted, −18 dB. This is the take the −18 dB measurement (194 mV pp) came from — use that pass if it is clean, or re-record at the identical setting. |
| S6 | The Bias field for CH2 set to Mid rail; the dotted line lands on the trace's centre. | 4:05 | A few seconds either side of the click, so the line's jump is visible. |
| S7 | Live: unplug the source and watch the bias climb back to 1.65 V, plug it back in and watch it collapse. | 5:10 | Hands off camera; only the app is recorded. This re-creates the first failure's tell without re-creating the failure itself. |
| S8 | The wrong 100 kΩ in the generator's RC: the Peak-to-peak readout stepping 440 Hz → 1 kHz → 5 kHz. | 7:10 | Numbers already on the bench (1.08 / 0.51 / 0.12 V) — match this take to them, or re-measure and update the script/production notes together. |
| S8b | The same sweep with the correct 1 kΩ back in, for the side-by-side. | 7:10 | Episode 1's S11 already has this exact reading (3.16 V pp through 1 kΩ + 10 nF) — reuse that footage before re-shooting it. |
| S9 | The Falstad simulator running the mini-AFE circuit, both channels. | 8:10 | Link goes in the description either way; this is only the shot. |
| S10 | The Mac app, CH1 and CH2 running together — the closing shot. | 8:40 | Can be the same take style as S1, wide enough to show both channels enabled. |

## Bench shots

Same two rules as episode 1: **light it and shoot down onto a plain
surface**, and **shoot landscape, always**.

| # | Shot | Used at | Notes |
| --- | --- | --- | --- |
| B1 | The breadboard, top-down, the MCP6022 in focus. | 0:00 / 1:15 | The steady-state shot of the finished circuit — reused wherever the script cuts to "the breadboard." |
| B2 | The parts laid out on white before anything goes in: the DIP-8, two 100 kΩ, two 1 kΩ, two 4.7 nF, one 1.5 µF, one 100 nF. | 1:15 | Fingers allowed. Count the pile on camera — eight parts, matching "that is the whole parts list." |
| B3 | The LM358 seated in the socket, close-up. | 3:05 | Matched to S3; same lighting and angle as B1 so the swap in B/S4 reads as a cut, not a different bench. |
| B4 | The 100 Ω resistor across the plug — tip to sleeve — close-up. | 4:05 | This is the correct wiring; keep a clean shot of it for contrast with B5. |
| B5 | The breadboard with the 100 Ω deliberately moved to the wrong side of the coupling capacitor — across the op amp's input instead of across the plug. | 5:10 | A recreation, not a re-enactment of an accident — say so if asked, don't claim it happened live on camera. Restore to B4's wiring immediately after the shot. |
| B6 | The two resistors side by side, close-up: brown-black-red and brown-black-yellow. | 7:10 | Macro lens or a phone's close-focus mode; the bands must be legible at 1080p. |
| B7 | The picoLABO PL2407AFE, populated. | 8:40 | Soldered before this shot was planned; the board is real hardware ready to go rather than a kit, which still reads as a tease. A different board entirely — keep it off the bench until this shot, same rule episode 1 used for B8. |

## Already have — do not re-shoot

| Asset | From | Used at |
| --- | --- | --- |
| `Shots/Clipped.png` | The evening of 2026-09-20 | 5:10 — Mean 324 mV, 780 mV pp, CLIP in the legend. The failure itself; a live re-shoot would not be honest. |
| `Shots/ClippedRepaired.png` | Same evening | 5:10 — Mean 1.67 V, 1.45 V pp, centred, no CLIP. Cuts against `Clipped.png` since they are the same window. |
| Episode 1's S11 footage | Episode 1 shoot | 7:10 (S8b) | 1 kΩ + 10 nF, pp 3.16 V — the correct-part reading for the resistor comparison. |

## Cards (generated, not filmed)

Built the same way as episode 1's (`cards.py`), not shot with a camera.

| Card | Reuse or new | Used at |
| --- | --- | --- |
| "0 – 3.3 V" | Reuse episode 1's `card_range.png` | 0:25 |
| A sine swinging about zero, only the part inside 0–3.3 V lit | Reuse episode 1's `card_swing.png` — it already draws exactly this | 0:25 |
| "100 kΩ ∥ 100 kΩ = 50 kΩ; 1.5 µF → 2.1 Hz" | New | 4:05 |
| "No protection · No attenuation · Keep the input inside the supply" | New | 8:10 |
| Schematic or board render for what's next | Reuse a KiCad preview from `hardware/pilyzer-afe/kicad/previews/` if one matches; otherwise a new render | 8:40 |

## Which board is on the bench when

Like episode 1, the bench does not simply sit wired — it changes twice on
purpose (the op-amp swap) and twice for a recreation (the two resistor
mistakes), then goes back.

| Shot | State |
| --- | --- |
| B2 (1:15) | **Loose parts** — nothing assembled. |
| B3 (3:05) | **LM358 fitted**, generator's raw carrier wired to the AC channel. |
| S4 (3:05) | **Swap to MCP6022.** Every shot after this one uses the MCP6022; the LM358 does not return. |
| B1 (0:00 / 1:15) | MCP6022 fitted — the steady state, reusable wherever "the breadboard" is needed. |
| B4 (4:05) | **100 Ω correct** — across the plug, tip to sleeve. |
| B5 (5:10) | **100 Ω moved** — across the op amp's input, recreating the second failure. Restore to B4 immediately after the shot; do not carry this into any later shot. |
| S8 / B6 (7:10) | **The generator's RC holds 100 kΩ** instead of 1 kΩ. Shoot the macro (B6) and the sweep (S8) in the same sitting without moving anything, then swap in the correct 1 kΩ. |
| S8b (7:10) | **The generator's RC holds 1 kΩ** — either the restored bench or episode 1's existing footage. |
| B7 (8:40) | A **different board** — the PL2407AFE, already populated (soldered ahead of this shot). Keep it off the bench until this shot. |

## Order to shoot in

1. B2 first, while the parts are still loose and unsoldered-looking.
2. Assemble with the LM358. Shoot B3 and S3 together, no camera move between
   them.
3. Swap to the MCP6022. Shoot S4, then B1 and S1 (the cold open can be shot
   any time from here on, since the bench does not change again until B5).
4. Wire 100 Ω correctly at the plug. Shoot B4, S5, S6.
5. Move the 100 Ω to the wrong side for B5, shoot it, then move it straight
   back.
6. Swap the generator's RC resistor to 100 kΩ. Shoot B6 and S8 together, then
   swap it back to 1 kΩ and shoot S8b (or confirm episode 1's footage still
   cuts in cleanly).
7. S7 (the unplug/replug) and S2 (the divider comparison) can be shot
   whenever the AC channel is wired correctly — any time after step 4.
8. S9 (simulator) and S10 (closing shot) do not need the physical bench at
   all; shoot them with the rest of the screen recordings.
9. B7 (PL2407AFE) last, off the bench until then.
