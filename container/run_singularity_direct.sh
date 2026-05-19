#!/bin/bash
# Direct-modern pipeline wrapper: Pythia → DELSIM → SDST → EDM4hep (direct).
#
# Parallels container/run_singularity.sh but adds a Stage 4 that runs
# delphi_sdst_to_edm4hep against the SDST in-process via the PHDST event
# loop. No nanoaod RNTuple intermediate, no SKELANA/PSALL stage, no
# delphi-raw-nanoaod build. Output is modern EDM4hep 1.0 / podio 1.7
# carrying everything the FCC ParticleTransformer flavor tagger needs:
#
#   * EFlowPhoton / EFlowNeutralHadron — neutral-PFO ECAL/HCAL clusters
#     split into the two collections FCC's JetFlavourHelper expects.
#   * SecondaryVertices with the OneToManyRelation `_SV_particles` populated
#     (the FCC tagger uses it for SV_mass / SV_ntrk / per-track SV linkage).
#   * Clusters with per-layer ECAL / per-hit HCAL drill-down for the
#     charged-PFO side.
#   * AllVertices (full LDTOP-1 chain: PV + DELPHI legacy SVs/V0s) +
#     AllVertices_statusBits.
#   * BeamSpot, Track_TEDetectorPattern / Track_TECount, ParticleID_dEdx /
#     Muon / Electron / HadronRich.
#   * Sigma-calibrated 5×5 helix covariance (F_d0=11, F_z0=19 from
#     truth-matched pull width study; see
#     _wt-edm4hep-direct/ild/README.md).
#
# Both pipelines start from the same Pythia → DELSIM Stage 1-3; this
# wrapper delegates those stages to run_singularity.sh and adds Stage 4.
# Reuses the same cmssw-el9 .sif image (no new container build needed —
# /cvmfs/sw.hsf.org/key4hep and /cvmfs/delphi.cern.ch are bind-mounted
# at runtime and satisfy both the DELPHI Fortran libs and key4hep deps).
#
# Prereqs on host:
#   * Same as run_singularity.sh (singularity-ce, /cvmfs autofs, etc.).
#   * delphi_sdst_to_edm4hep prebuilt at $DIRECT_BIN. Build with:
#
#       cd <delphi-improved-reco-direct-worktree>
#       singularity exec -B /cvmfs:/cvmfs:ro <image> \
#         bash -lc 'source /cvmfs/sw.hsf.org/key4hep/setup.sh -r 2026-04-08; \
#                   make bin/delphi_sdst_to_edm4hep'
#
# Usage (identical to run_singularity.sh):
#   ./run_singularity_direct.sh <n_events> <job_id> <out_dir> <config_file>
#                               [<delsim_version> <e_beam> <nrun>]
#
# Example:
#   ./run_singularity_direct.sh 200 mc_smoke /tmp/zbb ../config_z_bb.txt
#
# BS centroid override env vars (BS_X / BS_Y / BS_Z / BS_SIGMA_*) work
# identically — they're passed through to run_singularity.sh.
#
# Optional knobs for Stage 4 (env vars):
#   DIRECT_BIN            (path to delphi_sdst_to_edm4hep binary)
#   DIRECT_KEY4HEP_TAG    (key4hep release, default 2026-04-08)
#   DIRECT_EXTRA_ARGS     (extra args to delphi_sdst_to_edm4hep,
#                          e.g. --sigma-calibrated --perigee-momentum)

set -eo pipefail

N_EVENTS=${1:-200}
JOB_ID=${2:-$(date +%Y%m%d_%H%M%S)}
OUT_DIR=${3:-$PWD/out}
CONFIG_FILE=${4:-$PWD/../config_z_tautau.txt}
DELSIM_VERSION=${5:-v94c}
E_BEAM=${6:-45.625}
NRUN=${7:-${NRUN:-3101}}

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Direct-converter knobs.
DIRECT_BIN=${DIRECT_BIN:-/home/sqian/Codes/ee_Z_tatagamma/_wt-edm4hep-direct/bin/delphi_sdst_to_edm4hep}
DIRECT_KEY4HEP_TAG=${DIRECT_KEY4HEP_TAG:-2026-04-08}
DIRECT_EXTRA_ARGS=${DIRECT_EXTRA_ARGS:-}

# Same singularity image as the legacy wrapper.
IMAGE_DIR=${IMAGE_DIR:-$HOME/.cache/singularity-delphi}
IMAGE=$IMAGE_DIR/cmssw-el9-x86_64.sif

if [ ! -x "$DIRECT_BIN" ]; then
    echo "ERROR: delphi_sdst_to_edm4hep binary not found at $DIRECT_BIN" >&2
    echo "       Build it with key4hep $DIRECT_KEY4HEP_TAG sourced, e.g.:" >&2
    echo "         singularity exec -B /cvmfs:/cvmfs:ro $IMAGE \\" >&2
    echo "           bash -lc 'source /cvmfs/sw.hsf.org/key4hep/setup.sh -r $DIRECT_KEY4HEP_TAG; make bin/delphi_sdst_to_edm4hep'" >&2
    echo "       Override DIRECT_BIN to point at a different binary." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Stage 1-3 delegate to the existing wrapper. It produces:
#   $OUT_DIR/simana_${JOB_ID}.sdst       (always, on success)
#   $OUT_DIR/simana_${JOB_ID}.fadana     (always, on success — full DST)
echo "=== run_singularity_direct: delegating Stages 1-3 to run_singularity.sh ==="
"$HERE/run_singularity.sh" "$N_EVENTS" "$JOB_ID" "$OUT_DIR" "$CONFIG_FILE" \
    "$DELSIM_VERSION" "$E_BEAM" "$NRUN"

SDST="$OUT_DIR/simana_${JOB_ID}.sdst"
EDM4HEP="$OUT_DIR/simana_${JOB_ID}.edm4hep.root"

if [ ! -f "$SDST" ]; then
    echo "ERROR: Stage 1-3 did not produce $SDST" >&2
    exit 1
fi

# Bind-mount the direct converter binary's directory so it's visible
# inside the container at the same path. The binary is dynamically
# linked against /cvmfs/sw.hsf.org/key4hep (ROOT 6.38, podio 1.7,
# edm4hep 1.0, gcc 14 libstdc++) — sourcing the key4hep setup gives
# us those libs.
DIRECT_BIN_DIR="$(dirname "$DIRECT_BIN")"

echo "=== Stage 4: direct SDST → EDM4hep ($DIRECT_BIN -n $N_EVENTS) ==="
singularity exec --cleanenv \
    --bind /cvmfs --bind /lib64:/host_lib64:ro \
    --bind "$OUT_DIR:$OUT_DIR" \
    --bind "$DIRECT_BIN_DIR:$DIRECT_BIN_DIR:ro" \
    "$IMAGE" bash -c "
        set +u
        # DELPHI Fortran runtime (the direct converter links against
        # libphdstxx / libskelanaxx / etc. at /cvmfs/delphi.cern.ch).
        source /cvmfs/delphi.cern.ch/setup.sh > /dev/null 2>&1
        # Modern key4hep stack (ROOT 6.38 / podio 1.7 / edm4hep 1.0).
        source /cvmfs/sw.hsf.org/key4hep/setup.sh -r $DIRECT_KEY4HEP_TAG > /dev/null 2>&1
        # Host libs as fallback (matches run_singularity.sh's Stage 3).
        export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:/host_lib64

        # Run from a fresh subdir so PHDST scratch files don't collide
        # with the SDST one directory up. PHDST creates a basename-named
        # symlink to the input SDST plus assorted fort.* / PDLINPUT
        # bookkeeping; nuke the whole scratch on exit.
        SCRATCH=\$(mktemp -d -p \"$OUT_DIR\" stage4.XXXXXX)
        cd \"\$SCRATCH\"
        \"$DIRECT_BIN\" \"$SDST\" \"$EDM4HEP\" -n $N_EVENTS $DIRECT_EXTRA_ARGS
        STATUS=\$?
        cd \"$OUT_DIR\"
        rm -rf \"\$SCRATCH\" 2>/dev/null || true
        exit \$STATUS
    "

if [ -f "$EDM4HEP" ]; then
    echo "=== DONE: $EDM4HEP ==="
    echo "         (kept SDST + fadana alongside for re-conversion / fadana TE merge)"
else
    echo "=== Stage 4 did not produce $EDM4HEP — see logs above ==="
    exit 1
fi
