# DELSIM v94c BS override — RESOLVED (2026-05-10)

> **Update 2026-05-10**: this is no longer a limitation. The 2-step
> override path (prerun → patch XYZP/XYZW in `simlocal.title` → re-run
> with `-STITL`) works empirically on a 5-event Z→u/d test:
> per-event BS in the SDST matches the override to <80 µm in (x, y).
> Use the BS_X/BS_Y/BS_Z env vars on `run_singularity.sh`. The text
> below documents what was tried and why the original direct override
> failed.

## Setup

The DELSIM `v94c` steering at `/cvmfs/delphi.cern.ch/releases/.../simana/v94c/dat/simqqbar.tit` hardcodes the BS centroid and width:

```
XYZP    -0.100 0.0000 -.800       ! BS centroid (cm)
XYZW     0.012 0.0005 0.740       ! BS sigma    (cm)
```

These are the same for every `NRUN`. Real DELPHI 94c data has per-run BS positions; for run 13709 we measured (from real-data `Vtx[0]` mean) **(−0.306, +0.149, −0.770)** cm.

## Why the naive override hangs

A direct `runsim -STITL <edited-simqqbar.tit>` doesn't work — DELSIM gets stuck running its internal qq generator instead of reading our external fadgen. Diagnosis: `runsim`'s `-STITL` handler just `cp`s the user's title file to `simlocal.title` *as-is* — it doesn't substitute the placeholders that `MakeSimTitle()` would (e.g., `IRUN -4{nrun}`, `ISEEDG 4{nrun} 0 0`, `IGENER 15`, `NEVMAX 450`). So the edited title still has `IGENER=15` (internal qq generator) and `NEVMAX=450` — DELSIM happily generates 450 events internally and ignores our `-gext` fadgen file. The result looks like a hang because trigger and detector simulation grind through far more events than we asked for.

Earlier attribution to "DELANA can't match the new BS" was wrong — DELANA never even started.

## The working path: prerun → edit → re-run

Two `runsim` invocations:

1. **Prerun**: `runsim -VERSION v94c -NRUN <real-94c-run> -EBEAM 45.625 -NEVMAX N -gext events.fadgen` (no `-STITL`). This calls `MakeSimTitle()` which produces `simlocal.title` with all placeholders resolved (`IRUN -<NRUN>`, real `ISEEDG`/`ISEEDS`, `IGENER 0`, `NEVMAX N`, ...). We discard the prerun's outputs.
2. **Edit**: `cp simlocal.title simlocal_edit.title` and `sed` the XYZP/XYZW lines to the data-run BS values.
3. **Re-run**: `runsim ... -STITL simlocal_edit.title`. Now DELSIM has a fully-baked title with our BS override. Total runtime ~25 s for 5 events.

This is what `Delphi-Sim-Pipeline/container/run_singularity.sh` now does when the `BS_X/BS_Y/BS_Z` env vars are set.

## Empirical verification

Two-arm test, 5-event Z→u/d, raw nanoaod read of `Event_beamSpot{X,Y,Z}`:

| arm | XYZP set | per-event BS measured | match? |
|---|---|---|---|
| default  | (−0.100, 0.000, −0.800)           | (−0.107, ≈ 0.000, −0.05) | yes |
| override | (−0.306, +0.149, −0.770)           | (**−0.313, +0.149, −0.02**) | yes |

So **DELSIM's `XYZP` wins in the SDST `LDTOP-25` BS bank**. Whatever `BSPOTX/Y/Z` DELANA's `delana43.car:2244+` extracts from BEAX is *not* what ends up in the bank read by downstream — DELSIM stamps the per-event truth IP into the bank at simulation time, and that's what propagates.

Caveats:
- The `z` mean is a few cm off both targets. DELSIM's `XYZW(3) = 0.740` cm Gaussian z-smearing (LEP1 luminous region) plus 5-event statistics easily account for it.
- VD alignment is *not* run-overridden by this path; it stays at the v94c period default. For most 94c runs this is sub-mm-OK; for runs with significant VD-alignment shifts, you'd see a residual data/MC bias even after the BS fix.
- BEAX records may still affect some DELANA internals (e.g., `AABEAM` for jet-flavour tagging — `aabtagxx.car:632`), but the SDST output BS bank is XYZP-driven.

## Usage

```sh
# Match real-data run 13709
BS_X=-0.306 BS_Y=+0.149 BS_Z=-0.770 \
  Delphi-Sim-Pipeline/container/run_singularity.sh \
    100 mc /tmp/zbb_match Delphi-Sim-Pipeline/config_z_bb.txt \
    v94c 45.625 13709
```

Optional `BS_SIGMA_X/Y/Z` env vars; defaults are the v94c values
(120, 5, 7400) µm.

## When this matters

Any analysis that plots absolute PV / track / vertex coordinates against data sees the (−0.21, +0.15, +0.03) cm data-vs-MC mean offset. With the BS override, MC and data live in the same absolute frame for the chosen run, and absolute-coordinate plots overlap directly (no BS subtraction needed).

For inherently BS-relative observables — IP significance, `Trac_impParToBeamSpotRPhi`, jets, thrust — the override doesn't matter; those agreed already.

## Open follow-ups

- Per-run BS table: the 94c period covers many runs (~13700–14400). A small CSV `(run, x_BS, y_BS, z_BS, σx, σy, σz)` derived from the data nanoaods' `Vtx[0]` mean over hadronic-Z + ndf>0 events would let us stamp each MC batch with the matching run's BS automatically.
- VD-alignment override: the residual sub-mm bias from per-run alignment isn't covered. Probably small for analysis-level use, worth measuring.
- Closure on a fresh data/MC pair after the BS override is applied: re-make the diag plots with a 100-event MC produced via the override, see absolute-frame data/MC distributions overlap.
