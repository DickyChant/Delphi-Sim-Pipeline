# DELSIM v94c BS override — known limitation

## Summary

The DELSIM `v94c` steering file at
`/cvmfs/delphi.cern.ch/releases/.../simana/v94c/dat/simqqbar.tit`
hardcodes the beam-spot centroid and width:

```
XYZP    -0.100 0.0000 -.800       ! BS centroid (cm)
XYZW     0.012 0.0005 0.740       ! BS sigma    (cm)
```

These are **the same for every NRUN value**. Real DELPHI 94c data has
per-run BS positions; for run 13709 we measured (from real-data
`Vtx[0]` mean): `(-0.306, +0.149, -0.770)` cm.

A naive override via `runsim -STITL <edited-title>` (XYZP/XYZW patched
to data values) breaks the chain:

- DELSIM places events at the new BS, but DELANA's CDB BS prior is
  unchanged (the v94c-period default). DELANA's PV fit then fails on
  most events.
- Empirically: a 30-event run hung in DELANA at ~99% CPU; the trigger
  summary reported "Number of events analyzed: 376" (≈12× the request)
  — DELANA was retrying or fanning out subevents.

So **a single-source XYZP/XYZW edit is not sufficient** to make MC
match a specific data run's frame.

## What actually needs to change

To get MC and data into the same absolute frame for a chosen NRUN:

1. **DELSIM XYZP/XYZW** — controls where MC events are placed.
2. **DELANA's CDB BS prior** — controls where DELANA expects to find
   the IP during PV reconstruction.
3. **VD alignment** — the per-run alignment can shift the apparent
   IP by O(100 µm); also lives in CDB.

All three need to point at the same run's measured values. (1) is
straightforward via `-STITL`. (2) and (3) live in
`/cvmfs/delphi.cern.ch/condition-data` (read-only) and require either
patching the CDB locally or finding a DELANA option to override the
BS bank source.

## Recommended workflow today

Until the full per-run NRUN pipeline is built:

1. **Run DELSIM with default v94c XYZP** (`(-0.10, 0.00, -0.80)` cm) —
   this is internally consistent with DELANA's expected BS prior, so
   reconstruction succeeds.
2. **In analysis, do BS-relative comparisons.** The legacy nanoaod's
   `BeamSpot_*` fields are now correctly populated (after the
   2026-05-10 `fillBeamSpot` fix on `feature/sim-truth-pv` —
   `delphi-nanoaod` commit `6dfba6e`), and `delphi-raw-nanoaod` was
   already correct. Subtract `Event_beamSpot{X,Y,Z}` from any
   absolute-coordinate quantity (PV, track impact parameter, ...)
   before plotting data vs MC.
3. **For physics observables that are already BS-relative** —
   IP-significance, `Trac_impParToBeamSpotRPhi`, jet directions,
   thrust — the BS centroid offset is irrelevant; the data/MC
   comparison is meaningful as-is.

## When this matters

Any analysis that plots **absolute** PV / track / vertex coordinates
will see the (-0.21, +0.15, +0.03) cm data-vs-MC mean offset. The 5
mm `<|d0|>` charge split in both data and MC is reproduced by
`v94c` MC — that part of the modelling is fine.

## Future work

- Investigate whether `runsim` or `delana` accept a custom CDB BS
  source. If yes, the per-run override can be made to work.
- Otherwise, build a post-DELSIM event-shift step that translates
  events from MC frame to data frame; combined with re-running DELANA
  with a matching BS prior, this would close the absolute-frame gap.
- Either way, this is a v94c-wide problem, not specific to one run.
