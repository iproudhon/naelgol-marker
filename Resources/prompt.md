<!-- Default reconstruction prompt. Overridden at runtime with `golfctl reconstruct --prompt <path>`.
     Keep this file editable-and-rerunnable: do NOT inline it into Swift source. -->

# TODO(phase-3)

Draft after the first real transcript exists. Writing this before seeing what the
ASR actually produces would be guessing at the input.

What it has to do, from docs/research-game-tracking.md §7:

- Resolve acoustic speaker clusters to player names from content
  ("Nice shot, Steve" spoken by cluster 2 means Steve is not cluster 2).
- Segment the round into holes.
- Emit a shot list per player per hole: time, position, club if named, lie if named.
- Use golf's structural constraints as evidence: furthest from the hole plays first;
  strokes accumulate; every hole ends with an announced score.
- Emit per-shot `confidence`, and fill `conflicts[]` wherever constraints disagree.

Output is a reviewable draft, not an oracle. Say so in the instructions.
