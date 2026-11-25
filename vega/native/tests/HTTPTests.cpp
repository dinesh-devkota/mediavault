#include "Test.h"
#include <cstdlib>
#include <fstream>
using namespace mediavault;

namespace {
std::string environment(const char* name) {
    auto value = std::getenv(name); CHECK(value != nullptr); return value;
}
Source server() {
    return Source::parse({{"id", "https-fixture"}, {"kind", "webdav"},
        {"endpoint", environment("MEDIAVAULT_TEST_HTTPS")}, {"username", "cinevault"}, {"password", "fixture-only"}});
}
JSON request(const std::string& path, const std::string& method = "GET", int64_t maximum = 4096) {
    return {{"method", method}, {"path", path}, {"maximumBytes", maximum}};
}
std::string text(const HTTPResult& result) { return std::string(result.body.begin(), result.body.end()); }
HTTPResult fetch(const Source& source, const JSON& query) { return http(source, query, [] {}); }
std::vector<JSON> audit() {
    std::ifstream input(environment("MEDIAVAULT_TEST_HTTP_AUDIT")); CHECK(input.good());
    std::string line; std::vector<JSON> values;
    while (std::getline(input, line)) if (!line.empty()) values.push_back(JSON::parse(line));
    return values;
}
}

CASE(http_get_head_range) {
    auto source = server();
    auto result = fetch(source, request("bytes.bin"));
    CHECK(result.status == 200); CHECK(text(result) == "0123456789abcdef");
    CHECK(result.headers.at("content-length") == "16");
    auto head = fetch(source, request("bytes.bin", "HEAD", 0));
    CHECK(head.status == 200); CHECK(head.body.empty()); CHECK(head.headers.at("content-length") == "16");
    auto range = request("bytes.bin"); range["headers"] = {{"Range", "bytes=2-5"}};
    auto partial = fetch(source, range);
    CHECK(partial.status == 206); CHECK(text(partial) == "2345");
    CHECK(partial.headers.at("content-range") == "bytes 2-5/16"); CHECK(partial.headers.at("content-length") == "4");
}
CASE(http_unicode_query) {
    auto source = server(); auto query = request(u8"Été 日本語/a #1?.xml");
    query["query"] = {{"search", u8"a &?# 日本語"}};
    auto body = JSON::parse(text(fetch(source, query)));
    CHECK(body.at("path") == u8"/media/Été 日本語/a #1?.xml");
    CHECK(body.at("query").at("search").at(0) == u8"a &?# 日本語");
    auto propfind = request("Folder", "PROPFIND"); propfind["headers"] = {{"Depth", "1"}};
    auto listing = JSON::parse(text(fetch(source, propfind)));
    CHECK(listing.at("path") == "/media/Folder/"); CHECK(listing.at("method") == "PROPFIND");
    auto post = request("echo", "POST"); post["body"] = u8"synthetic request 日本語";
    CHECK(JSON::parse(text(fetch(source, post))).at("body") == u8"synthetic request 日本語");
}
CASE(http_authentication) {
    auto source = server(); source.password = "incorrect-fixture-password";
    CHECK(fetch(source, request("bytes.bin")).status == 401);
    source = server(); source.kind = "jellyfin"; source.token = "fixture-token";
    CHECK(fetch(source, request("bytes.bin")).status == 200);
    source.token = "invalid-fixture-token"; CHECK(fetch(source, request("bytes.bin")).status == 401);
}
CASE(http_redirect_credentials) {
    auto source = server();
    for (bool jellyfin : {false, true}) for (const std::string path : {"redirect", "redirect-http"}) {
        source.kind = jellyfin ? "jellyfin" : "webdav";
        source.token = jellyfin ? "fixture-token" : "";
        auto before = audit().size();
        test::rejected([&] { fetch(source, request(path)); });
        auto after = audit(); CHECK(after.size() == before + 1);
        CHECK(after.back().at("capture") == false);
        CHECK(after.back().at("path") == "/media/" + path);
        CHECK(after.back().at(jellyfin ? "token" : "authorization") == true);
    }
    for (const auto& item : audit()) CHECK(item.at("capture") == false);
}
CASE(http_certificate_validation) {
    auto source = server();
    for (const char* name : {"MEDIAVAULT_TEST_WRONG_HOST", "MEDIAVAULT_TEST_UNTRUSTED"}) {
        auto before = audit().size(); source.endpoint = environment(name);
        test::rejected([&] { fetch(source, request("bytes.bin")); });
        CHECK(audit().size() == before); // TLS must fail before Authorization is transmitted.
    }
    source = server(); CHECK(fetch(source, request("bytes.bin")).status == 200);
}
CASE(http_limits) {
    auto source = server();
    bool sizeLimit = false;
    try { fetch(source, request("oversized", "GET", 32)); }
    catch (const ResponseLimitError&) { sizeLimit = true; }
    CHECK(sizeLimit);
    test::rejected([&] { fetch(source, request("oversized-headers")); });
    test::rejected([&] { fetch(source, request("conflicting-headers")); });
    auto before = audit().size();
    test::rejected([&] { fetch(source, request("bytes.bin", "GET", -1)); });
    test::rejected([&] { fetch(source, request("bytes.bin", "GET", 16 * 1024 * 1024 + 1)); });
    CHECK(audit().size() == before);
}
CASE(http_untrusted_input) {
    auto source = server(); auto before = audit().size();
    for (const std::string path : {"../outside", "folder/%2e%2e/secret", "a\\b"})
        test::rejected([&] { fetch(source, request(path)); });
    for (const std::string endpoint : {"http://localhost:1/media", "https://user:pass@localhost:1/media",
            "https://localhost:1/media?token=test", "https://localhost:1/media#part"}) {
        auto invalid = source; invalid.endpoint = endpoint;
        test::rejected([&] { fetch(invalid, request("bytes.bin")); });
    }
    for (const std::string name : {"Host", "Authorization", "X-Emby-Token"}) {
        auto invalid = request("bytes.bin"); invalid["headers"] = {{name, "fixture"}};
        test::rejected([&] { fetch(source, invalid); });
    }
    auto header = request("bytes.bin"); header["headers"] = {{"Range", "bytes=0-1\r\nX-Injected: yes"}};
    test::rejected([&] { fetch(source, header); });
    for (const std::string name : {"api_key", "AccessToken"}) {
        auto invalid = request("bytes.bin"); invalid["query"] = {{name, "fixture"}};
        test::rejected([&] { fetch(source, invalid); });
    }
    source.kind = "jellyfin"; source.token = "fixture-token\r\nX-Injected: yes";
    test::rejected([&] { fetch(source, request("bytes.bin")); });
    source.token = std::string("fixture\0token", 13);
    test::rejected([&] { fetch(source, request("bytes.bin")); });
    CHECK(audit().size() == before);
}
CASE(http_profile_expiry) {
    auto marker = environment("MEDIAVAULT_TEST_PROFILE_MARKER");
    CHECK(!std::ifstream(marker).good());
    unsigned checks = 0;
    bool cancelled = false;
    try { http(server(), request("profile-expired", "GET", 0), [&] {
            ++checks;
            if (std::ifstream(marker).good()) throw UserError("Profile access expired");
        }); }
    catch (const ResponseLimitError&) { throw std::runtime_error("Cancellation must not become corrupt/oversized metadata"); }
    catch (const UserError& error) { cancelled = std::string(error.what()) == "Profile access expired"; }
    CHECK(cancelled);
    CHECK(std::ifstream(marker).good()); CHECK(checks > 1);
}
CASE(http_text_decoding) {
    auto invalid = fetch(server(), request("invalid-utf8"));
    CHECK(invalid.status == 200);
    auto decoded = JSON::parse(textResponse(invalid));
    CHECK(decoded.at("error").at("code") == "invalid-utf8"); CHECK(!decoded.contains("body"));
    for (const Bytes& bytes : std::vector<Bytes>{{0xc0, 0xaf}, {0xed, 0xa0, 0x80}, {0xf4, 0x90, 0x80, 0x80}, {0xe2, 0x82}})
        CHECK(JSON::parse(textResponse({200, bytes, {}})).at("error").at("code") == "invalid-utf8");
    const std::string valid = u8"<title>Été 日本語</title>";
    auto success = JSON::parse(textResponse({207, Bytes(valid.begin(), valid.end()), {{"content-type", "text/xml"}}}));
    CHECK(success.at("status") == 207); CHECK(success.at("body") == valid);
    CHECK(success.at("headers").at("content-type") == "text/xml");
}
CASE(http_error_status_oversized) {
    for (const int status : {401, 403, 500}) {
        auto result = fetch(server(), request("error/" + std::to_string(status) + "/oversized", "GET", 32));
        CHECK(result.status == status); CHECK(result.body.empty());
        const auto decoded = JSON::parse(textResponse(result));
        CHECK(decoded.at("status") == status); CHECK(decoded.at("body") == ""); CHECK(!decoded.contains("error"));
    }
}
CASE(http_error_status_encoding) {
    for (const int status : {401, 403, 500}) {
        auto result = fetch(server(), request("error/" + std::to_string(status) + "/invalid-utf8"));
        CHECK(result.status == status);
        const auto decoded = JSON::parse(textResponse(result));
        CHECK(decoded.at("status") == status); CHECK(decoded.at("body") == ""); CHECK(!decoded.contains("error"));
        // The text conversion boundary must remain safe even if a caller supplies
        // a non-success response directly rather than using this HTTP transport.
        const auto direct = JSON::parse(textResponse({status, {0xff}, {{"content-type", "text/html"}}}));
        CHECK(direct.at("status") == status); CHECK(direct.at("body") == ""); CHECK(!direct.contains("error"));
    }
}
CASE(http_error_status_cancellation) {
    const auto marker = environment("MEDIAVAULT_TEST_PROFILE_MARKER") + ".error";
    CHECK(!std::ifstream(marker).good());
    bool cancelled = false;
    try {
        http(server(), request("error/403/cancelled", "GET", 0), [&] {
            if (std::ifstream(marker).good()) throw UserError("Fixture profile changed during denied request");
        });
    } catch (const ResponseLimitError&) {
        throw std::runtime_error("Failed-response cancellation must not become corrupt content");
    } catch (const UserError& error) {
        cancelled = std::string(error.what()) == "Fixture profile changed during denied request";
    }
    CHECK(cancelled); CHECK(std::ifstream(marker).good());
}
