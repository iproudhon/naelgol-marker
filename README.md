# Marker

Golf round tracking and replay from **audio + GPS**, for the whole group.

A golf party narrates its own round — "you're away", "I'm hitting seven", "what'd you make?", "bogey".
Marker listens, records position and elevation, and reconstructs the round shot-by-shot for
**every player**, not just the phone's owner. Past rounds become a record you can replay, a map
you can walk back through, and a basis for suggesting the next shot.

> In golf, your *marker* is the person who keeps your score.

## Status

Pre-alpha. **Phase 1 (capture) works**: a round records to a session folder — segmented
audio, GPS, motion, barometric elevation, and MARKs — and reads back on a Mac. Nothing
reconstructs yet. See [`docs/PLAN.md`](docs/PLAN.md).

```sh
swift run golfctl record --out Sessions --players steve,dave --course "Naelgol CC"
swift run golfctl inspect Sessions/session-2026-08-24-1430
```

The iOS app is `Apps/Naelgol Marker/` — it builds; see its
[`SETUP.md`](Apps/Naelgol%20Marker/SETUP.md) for running it on a device.

## Layout

| Path | What |
|---|---|
| `Sources/` | Swift package targets — see [`docs/PLAN.md`](docs/PLAN.md) §3 |
| `Apps/Naelgol Marker/` | iOS app shell over the capture libraries — see its `SETUP.md` |
| `Resources/` | Default reconstruction prompt and output schema |
| `docs/` | Plan and the research that produced it |

## Docs

- [`docs/PLAN.md`](docs/PLAN.md) — product scope, architecture, roadmap
- [`docs/research-game-tracking.md`](docs/research-game-tracking.md) — feasibility research: audio, GPS, LLM reconstruction
- [`docs/poc-plan-round-reconstruction.md`](docs/poc-plan-round-reconstruction.md) — the PoC that gates everything

## License

MIT
