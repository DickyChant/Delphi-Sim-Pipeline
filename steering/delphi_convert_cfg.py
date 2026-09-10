import os

import FWCore.ParameterSet.Config as cms


def required(name):
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"{name} must be set")
    return value


def as_bool(value):
    return value.lower() in ("1", "true", "yes", "on")


def podio_input_tag(collection):
    # Input podio collection names containing underscores are reversibly
    # encoded when DelphiSource registers them with the framework.
    return cms.InputTag("c4hPodioEncoded" + collection.encode().hex())


process = cms.Process("DELPHI")
process.source = cms.Source(
    "DelphiSource",
    input=cms.untracked.string(required("DELPHI_INPUT")),
    inputMode=cms.untracked.string(os.environ.get("DELPHI_INPUT_MODE", "file")),
    conversionPass=cms.untracked.string(
        os.environ.get("DELPHI_CONVERSION_PASS", "sdst")
    ),
    intermediateFiles=cms.untracked.vstring(),
    isRealData=cms.untracked.bool(
        as_bool(os.environ.get("DELPHI_IS_REAL_DATA", "true"))
    ),
)
process.maxEvents = cms.untracked.PSet(
    input=cms.untracked.int32(int(os.environ.get("DELPHI_MAX_EVENTS", "-1")))
)
process.options = cms.untracked.PSet(numberOfThreads=cms.untracked.uint32(1))
process.delphiEventSummary = cms.EDProducer(
    "delphi_edm4hep::DelphiEventSummaryProducer",
    chargeCodes=podio_input_tag("sDST_MAIN_Particles_ChargeCode"),
)
process.output = cms.OutputModule(
    "PodioOutputModule",
    fileName=cms.untracked.string(required("DELPHI_OUTPUT")),
)
process.native_reconstruction = cms.Path(process.delphiEventSummary)
process.end = cms.EndPath(process.output)
