# Episode 1 — shot list

Two piles. **Screen** is a recording of the app or the page; **Bench** is a
camera pointed at hardware. Nothing else is needed — no b-roll, no stock.

Times are the script's section marks, not a promise.

## Screen recordings

Record at the display's native size and do not resize the window afterwards.
Record each one long; trim in the edit.

| # | Shot | Where | Notes |
| --- | --- | --- | --- |
| S1 | A trace, already running, filling the frame | 0:00 cold open | This is the first frame of the video. Crop to the plot area only — no menu bar, no dock. |
| S2 | Clicking through scope → spectrum → logic → logger | 0:25 | One slow pass, a beat on each. |
| S3 | The GitHub page | 0:40 | Two seconds. Scroll nothing. |
| S4 | The real connect: plug in, open page, Connect, the browser's device chooser, Run | 0:55 | **One take, no cuts.** The chooser is the point — it is the only permission there is. |
| S5 | The flat line, held | 1:20 | Must look boring. Five seconds is not too long. |
| S6 | Signal generator switched on, the sine appearing | 1:35 | Catch the moment it appears, not just the after. |
| S7 | Switch to Spectrum, the 440 Hz peak settling | 1:55 | Let it settle on camera. |
| S8 | The panel with the dotted bias line toggling on and off | 3:30 | The single most important shot in the episode. |
| S9 | The gain-correction note under a channel | 4:00 | Zoom in during the edit, not in the app. |
| S10 | The raw carrier with no RC — the mess | 4:45 | Same window position as S11 so they cut together. |
| S11 | The same input through 1 kΩ + 10 nF — the clean sine | 5:00 | Show the pp readout: 3.15 V. |
| S12 | The rate readout as channels are enabled and disabled | 5:45 | 495k → 247k → 165k. Hit all three. |
| S13 | The page on the Android phone over USB-C, running | 2:05 | Screen-record the phone if you can; otherwise this is a bench shot (B7). |

## Bench shots

One rule, and it carries the whole pile: **light it, and shoot down onto a
plain surface.** A desk lamp bounced off a white sheet of paper beats any
camera setting.

| # | Shot | Used at | Notes |
| --- | --- | --- | --- |
| B1 | Pico 2 + USB cable, alone, on plain white, top-down | 0:15 pull-back | Nothing else in frame. This is the "that's all it is" shot. |
| B2 | Hand plugging the USB cable into the board | 0:55 | Matched to S4. |
| B3 | The four generator pins, top-down and sharp | 4:15 | A pinout overlay goes on this in the edit, so leave headroom around the board. |
| B4 | One jumper from a generator pin to an input | 4:30 | Follow the wire with the eye from end to end. |
| B5 | The resistor and capacitor going in | 4:50 | Fingers allowed. Show the parts before they are in. |
| B6 | The logic header — eight resistors and a pin header | 6:15 | Cheap-and-cheerful is the point. |
| B7 | The phone next to the board, both running | 2:05 | Wide enough to show there is no computer. |
| B8 | The op amp on a breadboard, shallow focus, teasing | 6:45 | The next-episode shot. Deliberately not explained. |
| B9 | Thumbnail frame: front panel with a trace, board and cable beside it | — | Shoot this last, when the set is tidy. |

## On the one you already took (IMG_1523.png)

It is a real bench and that is worth something, but as a frame it works against
you three ways:

1. **Under-lit.** The whole picture sits in a dark vignette, and the board is
   dark-on-dark against the table. A phone camera in that light lifts the ISO
   and the noise eats the silkscreen — which is exactly the detail a viewer
   wants to read.
2. **Angled and low.** Shot from across the desk, so the breadboard is a
   lozenge and the rows do not line up with anything. Straight down, camera
   parallel to the board, makes wiring legible.
3. **Wires leave the frame on every edge**, and there are two spare
   breadboards and a perfboard in shot that the episode never mentions. The eye
   goes to the clutter.

Fixing it costs nothing: clear everything that is not in the shot, put a sheet
of white A4 or a cutting mat under the board, point a desk lamp at the ceiling
or a wall so the light arrives soft, and shoot from directly above with the
board's edge parallel to the frame. Tape the loose wires down.

The one thing worth keeping from that photo is the composition idea of showing
the board *in use* rather than posed — B7 and B8 are that, with the mess
removed.

## Order to shoot in

1. All the screen recordings in one sitting, while the app is configured and
   the window is where you want it. Do not quit the app between takes.
2. Tidy the bench. Then B1, B9.
3. Wire up and shoot B3–B6 in the order the episode builds them, so the
   hardware only ever gains parts and never loses them.
4. B7, B8 last.
