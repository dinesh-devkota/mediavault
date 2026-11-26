#include "Test.h"
#include <cstdlib>
#include <fstream>
using namespace mediavault;

namespace {
Source source() {
    // All traffic in this executable stays on the runner's synthetic loopback
    // fixture even if a transport guard regresses; never probe a real NAS.
    return Source::parse({{"id", "synthetic"}, {"kind", "smb"},
        {"endpoint", "smb://127.0.0.1:1445/MEDIALIBRARY"},
        {"username", "cinevault"}, {"password", "fixture-only"}});
}
template<class F> void blockedBeforeNetworking(F operation, const char* message) {
    bool matched = false;
    try { operation(); }
    catch (const UserError& error) { matched = std::string(error.what()) == message; }
    CHECK(matched);
}
size_t auditLines() {
    const auto path = std::getenv("MEDIAVAULT_TEST_HTTP_AUDIT"); CHECK(path != nullptr);
    std::ifstream input(path); CHECK(input.good());
    size_t lines = 0; std::string line;
    while (std::getline(input, line)) if (!line.empty()) ++lines;
    return lines;
}
}

CASE(fixture_transport_smb_allowed) {
    SMB library(source());
    const std::string file = "Movies/Library Feature (2020)/Library Feature (2020).mp4";
    CHECK(library.stat(file).at("size").get<uint64_t>() > 16);
    const auto bytes = library.read(file, 0, 16);
    CHECK(bytes.size() == 16);
    CHECK(std::string(bytes.begin() + 4, bytes.begin() + 8) == "ftyp");
    auto formats = source(); formats.endpoint = "smb://127.0.0.1:1445/FORMATPLAYBACK";
    SMB mkv(formats);
    const auto header = mkv.read("Feature.mkv", 0, 4);
    CHECK(header == Bytes({0x1a, 0x45, 0xdf, 0xa3}));
}

CASE(fixture_transport_smb_denied) {
    const char* expected = "This simulator test build accepts only its synthetic NAS and fixture sign-in.";
    for (const auto field : {"endpoint", "username", "password", "kind", "token", "userId"}) {
        auto invalid = source().serialized();
        invalid[field] = std::string(field) == "endpoint" ? "smb://127.0.0.1:1445/CINEVAULT" :
            std::string(field) == "kind" ? "webdav" : "rejected-fixture-value";
        const auto parsed = Source::parse(invalid);
        unsigned checks = 0;
        blockedBeforeNetworking([&] { SMB denied(parsed, [&] { ++checks; }); }, expected);
        CHECK(checks == 1); // Connection polling would perform further checks.
    }
}

CASE(fixture_transport_http_denied) {
    const auto endpoint = std::getenv("MEDIAVAULT_TEST_HTTPS"); CHECK(endpoint != nullptr);
    const auto before = auditLines();
    for (const auto kind : {"webdav", "jellyfin", "smb"}) {
        auto denied = source(); denied.kind = kind; denied.endpoint = endpoint;
        unsigned checks = 0;
        blockedBeforeNetworking([&] {
            http(denied, {{"method", "GET"}, {"path", "bytes.bin"}, {"maximumBytes", 32}}, [&] { ++checks; });
        }, "External servers are disabled in the simulator test build.");
        CHECK(checks == 1);
    }
    CHECK(auditLines() == before); // Even the trusted synthetic HTTPS server received no requests.
}
