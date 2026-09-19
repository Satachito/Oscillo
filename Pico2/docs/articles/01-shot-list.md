# Episode 1 — shot list

Japanese: [01-shot-list.ja.md](01-shot-list.ja.md).

Two piles. **Screen** is a recording of the **Mac app** — the episode leads
with it, and the browser version appears only on the phone (S13); **Bench** is
a camera pointed at hardware. Nothing else is needed — no b-roll, no stock.

Times are the script's section marks, not a promise.

## Screen recordings

Record at the display's native size and do not resize the window afterwards.
Record each one long; trim in the edit.

| # | Shot | Where | Notes |
| --- | --- | --- | --- |
| S1 | A trace, already running, filling the frame | 0:00 cold open | This is the first frame of the video. Crop to the plot area only — no menu bar, no dock. |
| S2 | Clicking through scope → spectrum → logic → logger | 0:25 | One slow pass, a beat on each. |
| S3 | The GitHub page | 0:40 | Two seconds. Scroll nothing. |
| S4 | The real connect in the Mac app: plug in, open the app, pick the board from the toolbar menu, Connect, Run | 0:55 | **One take, no cuts.** The point is that nothing else happens — no driver, no permission dialog. |
| S5 | The flat line, held | 1:20 | Must look boring. Five seconds is not too long. |
| S6 | Signal generator switched on, the sine appearing | 1:35 | Catch the moment it appears, not just the after. |
| S7 | Switch to Spectrum, the 1 kHz peak settling | 1:55 | Let it settle on camera. |
| S8 | The panel with the dotted bias line toggling on and off | 3:30 | The single most important shot in the episode. |
| S9 | The gain-correction note under a channel | 4:00 | Zoom in during the edit, not in the app. The kept take says −0.13 %, and the script says so. |
| S10 | The raw carrier with no RC — the mess | 4:45 | Same window position as S11 so they cut together. |
| S11 | The same input through 1 kΩ + 10 nF — the clean sine | 5:00 | Show the pp readout: 3.16 V in the kept take. Use a **film** 10 nF: an old ceramic 103 left ±0.5 V spikes on the sine. |
| S12 | The rate readout as channels are enabled and disabled | 5:45 | 495k → 247k → 165k. Hit all three. |
| S13 | The web version on the Android phone over USB-C, running | 2:05 | The kept take is a landscape camera shot of the phone beside the board, which covers B7 too. |

## Bench shots

Two rules, and they carry the whole pile. **Light it, and shoot down onto a
plain surface** — a desk lamp bounced off a white sheet of paper beats any
camera setting. And **shoot landscape, always**: a portrait frame cropped to
16:9 either loses the subject or arrives as a black-sided box. Landscape on a
phone is 4032 x 2268, which is 4K with room to spare.

Lay the board along the frame, or turn it about fifteen degrees so it reads as
a photograph rather than a diagram, and coil loose cable inside the frame
instead of letting it run off an edge.

| # | Shot | Used at | Notes |
| --- | --- | --- | --- |
| B1 | Pico 2 + USB cable, alone, on plain white, top-down | 0:15 pull-back | Nothing else in frame. This is the "that's all it is" shot. |
| B2 | Hand plugging the USB cable into the board | 0:55 | Matched to S4. |
| B3 | The four generator pins, top-down and sharp | 4:15 | A pinout overlay goes on this in the edit, so leave headroom around the board. |
| B4 | One jumper from a generator pin to an input | 4:30 | Follow the wire with the eye from end to end. |
| B5 | The resistor and capacitor going in | 4:50 | Fingers allowed. Show the parts before they are in. |
| B6 | The logic header — eight resistors and a pin header | 6:15 | Cheap-and-cheerful is the point. Logic is D0–D7 on physical pins 9–12 and 14–17 from firmware 1.13. |
| B7 | The phone next to the board, both running | 2:05 | Wide enough to show there is no computer. Not needed if S13 is the bench-camera take; the portrait still cannot be used. |
| B8 | The op amp on a breadboard, shallow focus, teasing | 6:45 | The next-episode shot. Deliberately not explained. |
| B9 | Thumbnail frame: the Mac app with a trace, board and cable beside it | — | Shoot this last, when the set is tidy. **16:9**, with the Mac window's title bar in frame. |

## Which board is on the bench when

The bench is not simply bare and then wired. The 4:15 section deliberately
rewinds and rebuilds, because that is the argument it is making, so the state
goes:

| Shot | State |
| --- | --- |
| B1 (0:15) | **Bare** — board and cable, nothing attached. |
| B2 (0:55) | **Wired** — on a small breadboard, one jumper from a generator pin to an input, 1 kΩ + 10 nF across it. The demo needs this: the sine at 1:35 comes back through that RC. |
| B3 (4:15) | **Bare** — a pinout overlay goes on this, and it wants clean silkscreen with nothing lying across it. |
| B4 (4:30) | **Bare plus one jumper, no RC** — the deliberately wrong version that produces the mess in S10. |
| B5 (4:50) | The R and C going in. Back to wired, on camera. |
| B6 (6:15) | Wired. The logic header alongside. |
| B7 (2:05) | Wired — it is the demo, with the phone. |
| B8 (6:45) | A **different** breadboard: the mini AFE with the MCP6022, connected to nothing. |

So shoot B4/S10 and B5/S11 as one sitting **without moving the camera**, because
they are a before and an after of the same frame.

B8 never appears wired in this episode. Keep it off the bench until the end so
it cannot wander into an earlier frame.

The board needs headers for anything in the wired state. If the one in B1 is a
fresh unsoldered board, that is the better B1 — but shoot B1 and B3 before you
solder, and use the headered board from B2 on.

## Recording setup (macOS)

The built-in recorder is enough. **⇧⌘5** → *Record Selected Portion*. There is
no "record this window" mode — you drag a region — which is actually what you
want here: set the region once and every take has the same crop, so S10 and
S11 cut together without a nudge in the edit.

In its **Options** menu, before the first take:

- **Remember Last Selection** on. This is the one that matters — it keeps the
  crop across takes.
- **Show Floating Thumbnail** off, or the previous take's thumbnail drifts into
  the next one.
- **Show Mouse Clicks** on for S4 (the connect flow, where the pointer is the
  story) and off for everything else. It is a per-take toggle.
- **Save to** a folder, not the desktop, or the desktop shots fill up with the
  files you are shooting.
- Microphone **off**. Narration is separate and already timed.

Around it: Focus / Do Not Disturb on, Dock hidden (⌥⌘D), desktop icons off
(`defaults write com.apple.finder CreateDesktop false; killall Finder` — put it
back afterwards). Crop above the menu bar if you would rather not show the
clock.

It captures at Retina resolution, so a window on a 2× display gives you room to
push in during the edit without softening. It records no system audio — nothing
needed here, but worth knowing if a later episode wants the app's sound.

**For S13 (the phone):** the phone's USB-C port is holding the Pico, so mirroring
over a cable is out. The kept take films the phone and the board together from
a tripod, which shows both the screen and that there is no computer.

## On the test photo

The first bench photo (since deleted) showed a real bench, which is worth
something, but as a frame it worked against itself three ways:

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

The one thing worth keeping from it is the idea of showing the board *in use*
rather than posed — B7 and B8 are that, with the mess
removed.

## Order to shoot in

1. All the screen recordings in one sitting, while the app is configured and
   the window is where you want it. Do not quit the app between takes.
2. Tidy the bench. Then B1, B9.
3. Wire up and shoot B3–B6 in the order the episode builds them, so the
   hardware only ever gains parts and never loses them.
4. B7, B8 last.
