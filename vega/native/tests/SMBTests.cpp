#include "Test.h"
#include <cstdlib>
using namespace mediavault;

namespace {
Source nas() {
    const char* endpoint = std::getenv("MEDIAVAULT_TEST_SMB");
    CHECK(endpoint != nullptr);
    return Source::parse({{"id", "smb-fixture"}, {"kind", "smb"}, {"endpoint", endpoint},
        {"username", "cinevault"}, {"password", "fixture-only"}});
}
bool entry(const JSON& listing, const std::string& path, bool directory) {
    for (const auto& item : listing)
        if (item.at("path") == path && item.at("directory") == directory) return true;
    return false;
}
std::string text(const Bytes& value) { return std::string(value.begin(), value.end()); }
}

CASE(smb_list_stat) {
    SMB smb(nas());
    auto root = smb.list(""); CHECK(entry(root, "Movies", true)); CHECK(entry(root, "NativeChecks", true));
    auto movies = smb.list("Movies"); CHECK(entry(movies, "Movies/Feature (2020)", true));
    auto files = smb.list("Movies/Feature (2020)");
    CHECK(entry(files, "Movies/Feature (2020)/Feature (2020).mp4", false));
    CHECK(entry(files, "Movies/Feature (2020)/bytes.bin", false));
    auto folder = smb.stat("Movies"); CHECK(folder.at("directory") == true);
    auto file = smb.stat("Movies/Feature (2020)/bytes.bin"); CHECK(file.at("directory") == false); CHECK(file.at("size") == 10);
    test::rejected([&] { smb.stat("Movies/Missing.mp4"); });
    test::rejected([&] { smb.list("Movies/Feature (2020)/bytes.bin"); });
}
CASE(smb_ranges) {
    SMB smb(nas()); const std::string path = "Movies/Feature (2020)/bytes.bin";
    CHECK(text(smb.read(path, 0, 10)) == "0123456789");
    CHECK(text(smb.read(path, 2, 4)) == "2345");
    CHECK(text(smb.read(path, 8, 20)) == "89");
    CHECK(smb.read(path, 10, 20).empty()); CHECK(smb.read(path, 0, 0).empty());
    test::rejected([&] { smb.read(path, 11, 1); });
    test::rejected([&] { smb.read(path, 0, 1024 * 1024 + 1); });
    test::rejected([&] { smb.read("Movies", 0, 1); });
    auto large = smb.read("NativeChecks/pattern.bin", 512 * 1024 - 7, 8192);
    CHECK(large.size() == 8192);
    for (size_t n = 0; n < large.size(); ++n) CHECK(large[n] == (512 * 1024 - 7 + n) % 251);
}
CASE(smb_unicode) {
    SMB smb(nas()); const std::string folder = u8"NativeChecks/Été 日本語";
    const std::string file = folder + u8"/Amélie #1 & famille.bin";
    CHECK(entry(smb.list("NativeChecks"), folder, true)); CHECK(entry(smb.list(folder), file, false));
    CHECK(smb.stat(file).at("size") == 17);
    CHECK(text(smb.read(file, 0, 32)) == "unicode-fixture\r\n");
    CHECK(text(smb.read(file, 8, 7)) == "fixture");
}
CASE(smb_authentication) {
    auto bad = nas(); bad.password = "wrong-fixture-password";
    test::rejected([&] { SMB denied(bad); });
    bad = nas(); bad.username = "unknown-fixture-account";
    test::rejected([&] { SMB denied(bad); });
    SMB valid(nas()); CHECK(valid.stat("Movies/Feature (2020)/bytes.bin").at("size") == 10);
}
CASE(smb_invalid_paths) {
    SMB smb(nas());
    for (const std::string path : {"../outside", "/Movies", "Movies/../NativeChecks", "Movies/%2e%2e/file", "Movies\\file"})
        test::rejected([&] { smb.read(path, 0, 1); });
    for (const std::string endpoint : {"smb://user:pass@127.0.0.1:1445/CINEVAULT", "smb://127.0.0.1:1445/CINEVAULT/nested",
            "https://127.0.0.1:1445/CINEVAULT", "smb://127.0.0.1:1445/CINEVAULT?token=test"}) {
        auto source = nas(); source.endpoint = endpoint; test::rejected([&] { SMB invalid(source); });
    }
}
