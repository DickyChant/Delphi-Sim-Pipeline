# Simple Pythia8 Pipeline for DELPHI Simulation

This repository provides a simple pipeline to run DELPHI detector simulation with **Pythia8** on **CERN lxplus** using Condor.

---

## 🚀 Configuration

### 1. Modify the submission script
Edit the **Arguments** section in `condor_delphi.sub`:

- `$1`: **Number of events per job**  
  ⚠️ Do **not** increase — this will cause failures.  
- `$2`: **Job name** (used as random number seed)  
- `$3`: **Output copy location** (must be your **AFS** area; EOS copy currently not supported)  
- `$4`: **Pythia config file** (e.g. `config_z_tautau.txt`)  

---

## 📦 Submission

Submit jobs with:

```bash
./submit_condor.sh
```

## ⚙️ Default Settings

- **Batches:** 10  
- **Jobs per batch:** 25  
- **Events per job:** ~2,500–3,000  

---

## 📂 Output Format

Each job now writes **two** ZEBRA/Fortran-binary files to the output dir:

- `simana_<job>.sdst` — DELPHI shortDST. Small (~150 kB / 30 events). Used by
  standard DELPHI analyses; the SKELANA-based delphi-nanoaod consumes this.
  Uniquely carries the **MVDH** VD-hit bank (event-level per-hit VD readout).
- `simana_<job>.fadana` — DELPHI full-DST (DELANA output). Larger (~500 kB /
  30 events) but carries the **per-track 3-D track elements** PA.TETP /
  TEID / TEOD / TEFA / TEFB that the shortDST strips. Needed for any
  hit-based refitting, particle-flow reconstruction, or alignment study.

The two files are complementary — you want both for a complete refit.

### 🔄 Convert to ROOT
Two options:
- [delphi-nanoaod](https://github.com/jingyucms/delphi-nanoaod) — the
  SKELANA-based RNTuple writer, the standard path.
- On the `feature/phdst-raw-reader` branch of that repo, the new
  `delphi-raw-nanoaod` executable walks the ZEBRA banks directly via PHDST
  and emits calorimeter cells, VD hits, track-element 3-D points, raw
  lepton-ID, beamspot, vertices, and the B field. Same RNTuple schema for
  `.sdst` and `.fadana` inputs — which collections populate depends on the
  file format. See `feature/phdst-raw-reader/delphi-raw-nanoaod/README.md`.

---

## 🐳 Local execution without CERN / Condor / Jingyu's image

Branch `feature/cmssw-el9-base` adds `container/run_singularity.sh` — a wrapper
that runs the full Pythia → DELSIM → DELANA → shortDST chain locally against
a vanilla `docker.io/cmssw/el9:x86_64` singularity image, with CVMFS
(`sft.cern.ch`, `delphi.cern.ch`) mounted at runtime and host
`/lib64` bind-mounted at `/host_lib64` for libgfortran / libXm / libXp /
libquadmath (which the `cmssw/el9` image does not ship). No CERN network,
no Condor, no Jingyu's private container needed.

Quickstart:
```bash
container/run_singularity.sh 200 smoketest /tmp/out config_z_tautau.txt
# -> /tmp/out/simana_smoketest.sdst
# -> /tmp/out/simana_smoketest.fadana
```
See `container/README.md` for the full prereq list.

### Per-run beam-spot override (`feature/expose-truth-vertex`)

DELSIM v94c hard-codes the BS centroid in `simqqbar.tit` (XYZP =
(−0.10, 0, −0.80) cm); real-data 94c BS is at (−0.31, +0.15, −0.77) cm,
so absolute-coord PV / track plots disagree between MC and data by
~2 mm in xy. Set `BS_X / BS_Y / BS_Z` env vars (with optional
`BS_SIGMA_*`) and DELSIM places events at the requested BS via a
prerun → `sed XYZP/XYZW` → re-run `runsim` sequence:

```bash
# Match real-data run 46004 (Y13709.* nanoaods on EOS):
BS_X=-0.3073 BS_Y=+0.1496 BS_Z=-0.7127 \
  container/run_singularity.sh 100 mc_match /tmp/zbb \
    config_z_bb.txt v94c 45.625 46004
```

Verified empirically: per-event BS in the resulting SDST matches the
override to <2 µm in (x, y). DELSIM XYZP wins over DELANA's BEAX prior
in the SDST BS bank. Full diagnosis: [`docs/bs-override.md`](docs/bs-override.md).
Per-run BS table (26 runs from 94c Y13709): in
[`delphi-improved-reco/diagnostics/bs_table_94c_Y13709.csv`](https://github.com/DickyChant/delphi-improve-reco/blob/feature/edm4hep-pipeline/diagnostics/bs_table_94c_Y13709.csv).
Closure plot showing matched MC overlapping data on the absolute frame:
slide 10 of [`delphi_improve_reco.pdf`](https://sqian.web.cern.ch/sqian/delphi_edm4hep/delphi_improve_reco.pdf)
on EOS.
