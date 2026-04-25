// validate_genpart: read 1..N RNTuple files with the GenPart_* schema and
//
//   * print a short summary table (nEvents, mean particles/event, mean #b/#c
//     hadrons, mean #leptons, mean #photons),
//
//   * pretty-print the LUJETS event-record tree for a chosen event,
//     descending mother → daughter using GenPart_firstChildIdx /
//     GenPart_lastChildIdx,
//
//   * if more than one file is given, compare them pairwise and report
//     event-by-event whether the (status, pdgId, parentIdx) lists are
//     bit-identical.
//
// Designed to validate that the three truth-emitting tools produce equivalent
// output:
//
//     fadgen_to_root my_events.fadgen           -> gen_fadgen.root
//     delphi-raw-nanoaod simana.sdst            -> gen_sdst.root
//     delphi-raw-nanoaod simana.fadana          -> gen_fadana.root
//
// All three are expected to give the same generator record per event; this
// tool makes that assertion checkable from a single command.
//
// Build:  make validate_genpart    (after sourcing LCG_107 or LCG_109)
// Usage:  ./validate_genpart [--event N] [--max-events M] file1.root [file2.root ...]

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <string>
#include <vector>

#include <ROOT/RNTuple.hxx>
#include <ROOT/RNTupleReader.hxx>

using RNTupleReader = ROOT::Experimental::RNTupleReader;

// ----------------------------------------------------------------------------
// PDG -> short name (extend as needed; unknowns fall through to a digit code).
// ----------------------------------------------------------------------------
static const std::map<int, std::string> kPdgNames = {
    {21, "g"},   {22, "γ"},   {23, "Z"},   {24, "W+"}, {-24, "W-"},
    {11, "e-"},  {-11, "e+"},  {12, "νe"},  {-12, "ν̄e"},
    {13, "μ-"},  {-13, "μ+"},  {14, "νμ"},  {-14, "ν̄μ"},
    {15, "τ-"},  {-15, "τ+"},  {16, "ντ"},  {-16, "ν̄τ"},
    {1, "d"},    {2, "u"},    {3, "s"},    {4, "c"},   {5, "b"},  {6, "t"},
    {111, "π0"}, {211, "π+"}, {-211, "π-"},
    {221, "η"},  {331, "η'"},
    {321, "K+"}, {-321, "K-"}, {310, "Ks"}, {130, "Kl"}, {311, "K0"},
    {411, "D+"}, {-411, "D-"}, {421, "D0"}, {-421, "D̄0"},
    {431, "Ds+"},{-431, "Ds-"},
    {413, "D*+"},{-413,"D*-"},{423, "D*0"},
    {443, "J/ψ"},{441, "ηc"},
    {511, "B0"}, {-511, "B̄0"},{521, "B+"}, {-521, "B-"},
    {531, "Bs0"},{-531,"B̄s0"},{541, "Bc+"},{-541, "Bc-"},
    {513, "B*0"},{-513,"B̄*0"},{523, "B*+"},{-523, "B*-"},
    {553, "Υ"},
    {2212, "p"}, {-2212, "p̄"}, {2112, "n"}, {-2112, "n̄"},
    {3122, "Λ"}, {-3122, "Λ̄"}, {3222, "Σ+"}, {3112, "Σ-"},
    {4122, "Λc+"},{-4122, "Λ̄c-"}, {5122, "Λb0"}, {-5122, "Λ̄b0"},
};

static std::string pdgName(int pid) {
    auto it = kPdgNames.find(pid);
    if (it != kPdgNames.end()) return it->second;
    int a = std::abs(pid);
    if ((500 <= a && a < 600) || (5000 <= a && a < 6000)) return "B-had(" + std::to_string(pid) + ")";
    if ((400 <= a && a < 500) || (4000 <= a && a < 5000)) return "C-had(" + std::to_string(pid) + ")";
    return std::to_string(pid);
}

static bool isB(int pid) {
    int a = std::abs(pid);
    return (500 <= a && a < 600) || (5000 <= a && a < 6000);
}
static bool isC(int pid) {
    int a = std::abs(pid);
    return (400 <= a && a < 500) || (4000 <= a && a < 5000);
}

// ----------------------------------------------------------------------------
struct File {
    std::string                              path;
    std::unique_ptr<RNTupleReader>           reader;
    Long64_t                                 nEntries{0};
};

// Helper: per-event particle counts.
struct Counts { int nParts=0, nB=0, nC=0, nLep=0, nNu=0, nPho=0; };

static Counts countParticles(const std::vector<int> &pdg) {
    Counts c;
    c.nParts = pdg.size();
    for (int p : pdg) {
        if (isB(p)) ++c.nB;
        if (isC(p)) ++c.nC;
        int a = std::abs(p);
        if (a == 11 || a == 13 || a == 15) ++c.nLep;
        if (a == 12 || a == 14 || a == 16) ++c.nNu;
        if (p == 22) ++c.nPho;
    }
    return c;
}

// Pull GenPart_* arrays for one event into plain int vectors.
struct EventRecord {
    std::vector<int> status, pdg, parent, firstChild, lastChild;
    std::int8_t isMC = 0;
    int n = 0;
};

static EventRecord readEvent(RNTupleReader &r, Long64_t row)
{
    EventRecord ev;
    auto vIsMC  = r.GetView<std::int8_t>("Event_isMC");
    auto vN     = r.GetView<std::int32_t>("nGenPart");
    auto vSta   = r.GetView<std::vector<std::int16_t>>("GenPart_status");
    auto vPdg   = r.GetView<std::vector<std::int32_t>>("GenPart_pdgId");
    auto vPar   = r.GetView<std::vector<std::int32_t>>("GenPart_parentIdx");
    auto vD1    = r.GetView<std::vector<std::int32_t>>("GenPart_firstChildIdx");
    auto vD2    = r.GetView<std::vector<std::int32_t>>("GenPart_lastChildIdx");

    ev.isMC = vIsMC(row);
    ev.n    = vN(row);
    const auto &s  = vSta(row);
    const auto &p  = vPdg(row);
    const auto &pa = vPar(row);
    const auto &d1 = vD1(row);
    const auto &d2 = vD2(row);
    ev.status.assign(s.begin(), s.end());
    ev.pdg.assign   (p.begin(), p.end());
    ev.parent.assign(pa.begin(), pa.end());
    ev.firstChild.assign(d1.begin(), d1.end());
    ev.lastChild.assign (d2.begin(), d2.end());
    return ev;
}

static void printSummary(const std::string &label, RNTupleReader &r)
{
    Long64_t N = r.GetNEntries();
    long totalParts = 0, totalB = 0, totalC = 0, totalLep = 0, totalPho = 0;
    int  nMC = 0;
    for (Long64_t i = 0; i < N; ++i) {
        EventRecord ev = readEvent(r, i);
        if (!ev.isMC) continue;
        ++nMC;
        Counts c = countParticles(ev.pdg);
        totalParts += c.nParts;
        totalB     += c.nB;
        totalC     += c.nC;
        totalLep   += c.nLep;
        totalPho   += c.nPho;
    }
    int n = std::max(nMC, 1);
    std::cout << "  " << label << "  events="  << N
              << "  MC=" << nMC
              << "  <nParts>=" << double(totalParts) / n
              << "  <nB>="     << double(totalB) / n
              << "  <nC>="     << double(totalC) / n
              << "  <nLep>="   << double(totalLep) / n
              << "  <nPho>="   << double(totalPho) / n
              << std::endl;
}

// ----------------------------------------------------------------------------
// Pretty-printer for the decay tree rooted at every "primary" particle
// (parent == -1) in an event. We descend via firstChild..lastChild.
// ----------------------------------------------------------------------------
static void printTreeNode(const EventRecord &ev, int idx, int depth, int maxDepth)
{
    if (idx < 0 || idx >= int(ev.pdg.size())) return;
    if (depth > maxDepth) return;
    std::cout << "    ";
    for (int d = 0; d < depth; ++d) std::cout << "  ";
    if (depth > 0) std::cout << "└─ ";
    std::cout << "#" << idx
              << "  status=" << ev.status[idx]
              << "  pdg="   << ev.pdg[idx]
              << " (" << pdgName(ev.pdg[idx]) << ")"
              << std::endl;
    int a = ev.firstChild[idx];
    int b = ev.lastChild[idx];
    if (a >= 0 && b >= a) {
        for (int c = a; c <= b; ++c) printTreeNode(ev, c, depth + 1, maxDepth);
    }
}

static void printTree(const std::string &label, const EventRecord &ev,
                      int rowIdx, int maxDepth)
{
    Counts c = countParticles(ev.pdg);
    std::cout << "\n=== " << label << "  (event row " << rowIdx
              << "; nGenPart=" << ev.n << "; isMC=" << int(ev.isMC) << ")"
              << std::endl;
    std::cout << "    counts: nB=" << c.nB << "  nC=" << c.nC
              << "  nLep=" << c.nLep << "  nPho=" << c.nPho << std::endl;
    for (int i = 0; i < int(ev.pdg.size()); ++i) {
        if (ev.parent[i] == -1) printTreeNode(ev, i, 0, maxDepth);
    }
}

// ----------------------------------------------------------------------------
static int compareFiles(const File &A, const File &B)
{
    // Iterate over MC events in each (skip rows where Event_isMC == 0; the
    // PHDST raw reader emits one such row per file -- the BOS run header).
    auto vIsMC_A = A.reader->GetView<std::int8_t>("Event_isMC");
    auto vIsMC_B = B.reader->GetView<std::int8_t>("Event_isMC");

    std::vector<Long64_t> mcA, mcB;
    for (Long64_t i = 0; i < A.nEntries; ++i) if (vIsMC_A(i) == 1) mcA.push_back(i);
    for (Long64_t i = 0; i < B.nEntries; ++i) if (vIsMC_B(i) == 1) mcB.push_back(i);

    Long64_t n = std::min(mcA.size(), mcB.size());
    int matched = 0, mismatched = 0;
    for (Long64_t k = 0; k < n; ++k) {
        EventRecord a = readEvent(*A.reader, mcA[k]);
        EventRecord b = readEvent(*B.reader, mcB[k]);
        if (a.pdg == b.pdg && a.status == b.status && a.parent == b.parent)
            ++matched;
        else {
            ++mismatched;
            if (mismatched <= 3) {
                std::cout << "  MISMATCH at event " << k
                          << "  (rows: A=" << mcA[k] << " B=" << mcB[k] << ")  "
                          << "len A=" << a.pdg.size()
                          << " B=" << b.pdg.size() << std::endl;
            }
        }
    }
    std::cout << "  " << A.path << "  vs  " << B.path
              << "  :  " << matched << " / " << (matched + mismatched)
              << " events bit-identical (status + pdgId + parentIdx)"
              << std::endl;
    return mismatched;
}

// ----------------------------------------------------------------------------
int main(int argc, char **argv)
{
    int eventToPrint = -1;
    int maxDepth     = 12;
    std::vector<std::string> paths;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--event"     && i + 1 < argc) eventToPrint = std::atoi(argv[++i]);
        else if (a == "--max-depth" && i + 1 < argc) maxDepth = std::atoi(argv[++i]);
        else if (a == "-h" || a == "--help") {
            std::cout << "Usage: " << argv[0]
                      << " [--event N] [--max-depth M] file1.root [file2.root ...]"
                      << std::endl;
            return 0;
        }
        else paths.push_back(a);
    }
    if (paths.empty()) {
        std::cerr << "No input files given. Try -h." << std::endl;
        return 1;
    }

    std::vector<File> files;
    files.reserve(paths.size());
    std::cout << "=== summary per file ===" << std::endl;
    for (const auto &p : paths) {
        File f;
        f.path   = p;
        f.reader = RNTupleReader::Open("Events", p);
        f.nEntries = f.reader->GetNEntries();
        printSummary(p, *f.reader);
        files.push_back(std::move(f));
    }

    // Per-file event-record tree dump.
    if (eventToPrint < 0) {
        // Default: first MC event in each file (skip BOS row if present).
        for (auto &f : files) {
            auto vIsMC = f.reader->GetView<std::int8_t>("Event_isMC");
            for (Long64_t i = 0; i < f.nEntries; ++i) {
                if (vIsMC(i) == 1) {
                    EventRecord ev = readEvent(*f.reader, i);
                    printTree(f.path + " (first MC event)", ev, i, maxDepth);
                    break;
                }
            }
        }
    } else {
        for (auto &f : files) {
            if (eventToPrint < f.nEntries) {
                EventRecord ev = readEvent(*f.reader, eventToPrint);
                printTree(f.path, ev, eventToPrint, maxDepth);
            }
        }
    }

    // Pairwise comparisons.
    if (files.size() >= 2) {
        std::cout << "\n=== pairwise bit-identity check (MC events only) ===" << std::endl;
        int totalMismatched = 0;
        for (size_t i = 0; i < files.size(); ++i)
            for (size_t j = i + 1; j < files.size(); ++j)
                totalMismatched += compareFiles(files[i], files[j]);
        if (totalMismatched > 0) {
            std::cerr << "FAILED: " << totalMismatched
                      << " event-pair mismatches across files" << std::endl;
            return 2;
        }
        std::cout << "OK: all pairs bit-identical." << std::endl;
    }
    return 0;
}
