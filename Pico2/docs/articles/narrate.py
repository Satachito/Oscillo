#!/usr/bin/env python3
"""Speaks the script with `say`, then rewrites the captions to match it.

The timings in the caption files start as estimates from the script's beats.
This replaces them with the truth: each cue is synthesised on its own, measured,
and laid end to end, so the subtitles and the narration cannot drift apart.

    python3 narrate.py                     # the System Voice, default pace
    python3 narrate.py --voice Samantha --rate 165

The episode's narration is **Siri Voice 5**, chosen on 2026-09-19 over
Samantha and Zoe (Premium). `say` cannot name a Siri voice, so it is reached
as the System Voice: set System Settings -> Accessibility -> Spoken Content ->
System Voice to Siri Voice 5 before running this, or the narration comes out
in whatever voice is set there instead.

Leaves one audio file per cue in `narration/`, which is what an editor wants —
they go against the picture one at a time — plus `narration/full.m4a` for a
rough cut. The audio is not committed; this script and the captions are.

Better voices than the ones macOS ships with are a download away:
System Settings -> Accessibility -> Spoken Content -> System Voice ->
Manage Voices. The Enhanced and Premium entries are a different class from
Samantha and Alex, and worth the few hundred megabytes for narration.
"""
import argparse, pathlib, re, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
EN, JA = HERE / '01-captions.en.vtt', HERE / '01-captions.ja.vtt'

parser = argparse.ArgumentParser()
parser.add_argument('--voice', default='system',
                    help='a name from `say -v ?`, or "system" for the System Voice '
                         '(the only way to reach a Siri voice, which `say` cannot name)')
parser.add_argument('--rate', type=int, default=170, help='words a minute')
parser.add_argument('--gap', type=float, default=0.35, help='seconds between cues')
parser.add_argument('--section-gap', type=float, default=2.5,
                    help='seconds before a cue marked "NOTE section", for the picture to speak')
parser.add_argument('--out', default='narration')
args = parser.parse_args()

CUE = re.compile(r'^(\d+)\n([\d:.]+) --> ([\d:.]+)\n(.*?)(?=\n\n|\Z)', re.M | re.S)

def cues(path):
    body = path.read_text().split('\n\n', 2)[2]
    # A "NOTE section" marks a beat where the picture carries it alone, so the
    # narration waits rather than running the sections together.
    body = '\n\n'.join(b for b in body.split('\n\n') if not b.startswith('NOTE'))
    return [(int(n), text.strip()) for n, _, _, text in CUE.findall('\n' + body.strip() + '\n\n')]

def section_starts(path):
    blocks = path.read_text().split('\n\n')
    return {int(blocks[i + 1].split('\n')[0])
            for i, b in enumerate(blocks[:-1]) if b.strip() == 'NOTE section'}

def stamp(seconds):
    ms = round(seconds * 1000)
    return f'{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02}.{ms % 1000:03}'

def duration(path):
    out = subprocess.run(['afinfo', str(path)], capture_output=True, text=True).stdout
    found = re.search(r'estimated duration: ([\d.]+) sec', out)
    if not found: sys.exit(f'could not measure {path}')
    return float(found.group(1))

english = cues(EN)
japanese = dict(cues(JA))
if sorted(japanese) != [n for n, _ in english]:
    sys.exit('the two caption files no longer carry the same cues')

out = HERE / args.out
shutil.rmtree(out, ignore_errors=True)
out.mkdir()

sections = section_starts(EN)
VOICE = [] if args.voice == 'system' else ['-v', args.voice]

# `say` does not hand back exactly the silence it was asked for, so the gaps
# are synthesised first and measured, and the captions are built from what the
# files actually are. Assuming here is what makes a rough cut drift.
for name, seconds in (('gap.aiff', args.gap), ('section.aiff', args.section_gap)):
    subprocess.run(['say', *VOICE, '-o', str(out / name),
                    '[[slnc %d]]' % round(seconds * 1000)], check=True)
gap, section_gap = duration(out / 'gap.aiff'), duration(out / 'section.aiff')

at, times = 0.0, {}
for number, text in english:
    if number in sections: at += section_gap
    # The caption is broken for reading; the voice wants it as one sentence.
    spoken = ' '.join(text.split('\n')).replace('—', ',')
    piece = out / f'{number:03}.aiff'
    subprocess.run(['say', *VOICE, '-r', str(args.rate), '-o', str(piece), spoken], check=True)
    length = duration(piece)
    times[number] = (at, at + length)
    at += length + gap

def retime(path, texts, marks):
    header, _, _ = path.read_text().partition('\n\n1\n')
    blocks = []
    for n, (a, b) in sorted(times.items()):
        if n in marks: blocks.append('NOTE section')
        blocks.append(f'{n}\n{stamp(a)} --> {stamp(b)}\n{texts[n]}')
    path.write_text(header + '\n\n' + '\n\n'.join(blocks) + '\n')

retime(EN, dict(english), sections)
retime(JA, japanese, sections)

# One file for a rough cut, with the same gaps the captions were given — a
# rough cut that drifts from its own subtitles would be worse than none.
listing = out / 'concat.txt'
lines = []
for number, _ in english:
    if number in sections: lines.append("file 'section.aiff'\n")
    lines.append(f"file '{number:03}.aiff'\n")
    lines.append("file 'gap.aiff'\n")
listing.write_text(''.join(lines))
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0',
                '-i', str(listing), '-c:a', 'aac', '-b:a', '128k', str(out / 'full.m4a')], check=True)

print(f'{len(english)} cues, {args.voice} at {args.rate} wpm -> {at:.1f} s ({at/60:.1f} min)')
print(f'{out}/NNN.aiff one per cue, {out}/full.m4a for a rough cut')
for path in (EN, JA):
    text = path.read_text()
    text = text.replace('Timings are estimated from the script\'s beats, not from a recording. After the',
                        'Timings are measured from the synthesised narration by narrate.py. After the')
    path.write_text(text)
print('caption timings replaced with the measured ones')
