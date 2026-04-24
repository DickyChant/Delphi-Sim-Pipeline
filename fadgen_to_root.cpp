// fadgen -> RNTuple converter.
//
// Reads the Fortran-binary FADGEN file produced by pythia8_generate (the
// `fort.26` / `my_events.fadgen` used as DELSIM input) and writes a flat ROOT
// RNTuple whose GenPart_* schema is intentionally identical to the one the
// sibling delphi-raw-nanoaod emits when it unpacks the DST-level simulation
// banks. This lets downstream analysis code consume the same tree whether
// the truth came directly from Pythia (no DST round-trip) or was recovered
// from a shortDST / fullDST.
//
// FADGEN record layout (pythia8_generate.cpp:220-265):
//     int32 record_size  (= 4 + 60*n)
//     int32 n            (number of particles in the event)
//     for each particle:
//         int32 k[5]     (status, pdg, mother, firstDaughter, lastDaughter)
//         float p[5]     (px, py, pz, E, m)
//         float v[5]     (vx, vy, vz, t, tau)   -- all zero in the Pythia8
//                                                  writer, fields are kept
//                                                  for schema parity
//     int32 record_size  (trailing, same value)
// End-of-stream marker: record with n == 0.
//
// Indexing convention translation:
//     FADGEN k[2..4] use 1-based indices, 0 for "none"
//     GenPart_*Idx   use 0-based indices, -1 for "none"
//
// No DELPHI / SKELANA dependency -- only ROOT. Build target in the Makefile.

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <ROOT/RNTuple.hxx>
#include <ROOT/RNTupleModel.hxx>
#include <ROOT/RNTupleWriter.hxx>
#include <Math/Vector3D.h>
#include <Math/Vector4D.h>

using XYZVectorF = ROOT::Math::DisplacementVector3D<
    ROOT::Math::Cartesian3D<float>,
    ROOT::Math::DefaultCoordinateSystemTag>;

using XYZTVectorF = ROOT::Math::LorentzVector<
    ROOT::Math::PxPyPzE4D<float>>;

using RNTupleWriter = ROOT::Experimental::RNTupleWriter;
using RNTupleModel  = ROOT::Experimental::RNTupleModel;

template <typename T>
static std::shared_ptr<T>
makeField(RNTupleModel &model,
          const std::string &name, const std::string &desc)
{
    return model.MakeField<T>({name, desc});
}

static bool readInt32(std::istream &in, std::int32_t &out) {
    char buf[4];
    in.read(buf, 4);
    if (in.gcount() != 4) return false;
    std::memcpy(&out, buf, 4);
    return true;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        std::cerr << "Usage: " << argv[0] << " <input.fadgen> <output.root>"
                  << std::endl;
        return 1;
    }
    const std::string in_path  = argv[1];
    const std::string out_path = argv[2];

    std::ifstream in(in_path, std::ios::binary);
    if (!in) {
        std::cerr << "Cannot open " << in_path << std::endl;
        return 1;
    }

    auto model = RNTupleModel::Create();
    auto Event_isMC             = makeField<std::int8_t >(*model, "Event_isMC",             "1 by construction -- fadgen is always MC");
    auto Event_indexInFile      = makeField<std::int32_t>(*model, "Event_indexInFile",      "0-based record index in the fadgen stream");
    auto nGenPart               = makeField<std::int32_t>(*model, "nGenPart",               "Number of LUJETS particles in this event");
    auto GenPart_status         = makeField<std::vector<std::int16_t>>(*model, "GenPart_status",
        "FADGEN k[0]: JETSET status code. pythia8_generate maps Pythia8 status codes to JETSET "
        "(final-state = 1, intermediate = 2, beam = 21, V0 = 4, etc.). See convertToJetsetStatus.");
    auto GenPart_pdgId          = makeField<std::vector<std::int32_t>>(*model, "GenPart_pdgId",          "FADGEN k[1]: PDG particle code");
    auto GenPart_parentIdx      = makeField<std::vector<std::int32_t>>(*model, "GenPart_parentIdx",      "FADGEN k[2] - 1: parent index (-1 if none)");
    auto GenPart_firstChildIdx  = makeField<std::vector<std::int32_t>>(*model, "GenPart_firstChildIdx",  "FADGEN k[3] - 1: first-daughter index (-1 if none)");
    auto GenPart_lastChildIdx   = makeField<std::vector<std::int32_t>>(*model, "GenPart_lastChildIdx",   "FADGEN k[4] - 1: last-daughter index (-1 if none)");
    auto GenPart_fourMomentum   = makeField<std::vector<XYZTVectorF>> (*model, "GenPart_fourMomentum",   "FADGEN p[0..3]: (px, py, pz, E) in GeV");
    auto GenPart_mass           = makeField<std::vector<float>>       (*model, "GenPart_mass",           "FADGEN p[4]: generator mass in GeV");
    auto GenPart_vertex         = makeField<std::vector<XYZVectorF>>  (*model, "GenPart_vertex",
        "FADGEN v[0..2]: production vertex (mm). pythia8_generate currently "
        "writes all zeros, but the field is kept for schema parity with the "
        "DST-based GenPart_vertex.");
    auto GenPart_productionTime = makeField<std::vector<float>>       (*model, "GenPart_productionTime", "FADGEN v[3]: production time");
    auto GenPart_properLifetime = makeField<std::vector<float>>       (*model, "GenPart_properLifetime", "FADGEN v[4]: proper lifetime");

    auto writer = RNTupleWriter::Recreate(std::move(model), "Events", out_path);

    std::int32_t evIndex = 0;
    std::int64_t totalParticles = 0;

    while (true) {
        std::int32_t headerSize = 0;
        if (!readInt32(in, headerSize)) break;          // EOF

        std::int32_t n = 0;
        if (!readInt32(in, n)) {
            std::cerr << "Unexpected EOF reading record count" << std::endl;
            return 2;
        }

        if (n <= 0) {
            std::int32_t trailer = 0;
            readInt32(in, trailer);                     // consume end marker
            break;
        }

        const std::int32_t expectedPayload = 60 * n;
        if (headerSize != 4 + expectedPayload) {
            std::cerr << "Record size mismatch at event " << evIndex
                      << ": got " << headerSize
                      << ", expected " << (4 + expectedPayload) << std::endl;
            return 2;
        }

        GenPart_status->clear();
        GenPart_pdgId->clear();
        GenPart_parentIdx->clear();
        GenPart_firstChildIdx->clear();
        GenPart_lastChildIdx->clear();
        GenPart_fourMomentum->clear();
        GenPart_mass->clear();
        GenPart_vertex->clear();
        GenPart_productionTime->clear();
        GenPart_properLifetime->clear();

        for (int i = 0; i < n; ++i) {
            std::int32_t k[5];
            float        p[5];
            float        v[5];
            in.read(reinterpret_cast<char*>(k), 20);
            in.read(reinterpret_cast<char*>(p), 20);
            in.read(reinterpret_cast<char*>(v), 20);
            if (!in) {
                std::cerr << "Unexpected EOF inside event " << evIndex
                          << " particle " << i << std::endl;
                return 2;
            }
            GenPart_status->push_back(static_cast<std::int16_t>(k[0]));
            GenPart_pdgId->push_back(k[1]);
            GenPart_parentIdx->push_back(k[2] - 1);
            GenPart_firstChildIdx->push_back(k[3] - 1);
            GenPart_lastChildIdx->push_back(k[4] - 1);
            GenPart_fourMomentum->push_back(XYZTVectorF(p[0], p[1], p[2], p[3]));
            GenPart_mass->push_back(p[4]);
            GenPart_vertex->push_back(XYZVectorF(v[0], v[1], v[2]));
            GenPart_productionTime->push_back(v[3]);
            GenPart_properLifetime->push_back(v[4]);
        }

        // Trailing record_size.
        std::int32_t trailer = 0;
        if (!readInt32(in, trailer) || trailer != headerSize) {
            std::cerr << "Trailing record size mismatch at event " << evIndex
                      << std::endl;
            return 2;
        }

        *Event_isMC = 1;
        *Event_indexInFile = evIndex;
        *nGenPart = n;
        writer->Fill();

        totalParticles += n;
        ++evIndex;
    }

    writer.reset();   // commit

    std::cout << "Wrote " << out_path << " : " << evIndex
              << " events, " << totalParticles << " particles total"
              << std::endl;
    return 0;
}
