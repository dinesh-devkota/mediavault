#include "Test.h"
#include "Relay.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <iomanip>
#include <thread>
#if defined(MEDIAVAULT_RELAY_TRACE_TEST)
#include <regex>
#endif
using namespace mediavault;
using namespace std::chrono_literals;

namespace {
struct Address { uint16_t port; std::string path; };
Address address(const std::string& uri) {
    const std::string prefix = "http://127.0.0.1:";
    CHECK(uri.compare(0, prefix.size(), prefix) == 0);
    auto slash = uri.find('/', prefix.size());
    CHECK(slash != std::string::npos);
    return {uint16_t(std::stoul(uri.substr(prefix.size(), slash - prefix.size()))), uri.substr(slash)};
}
struct Socket {
    int fd;
    explicit Socket(const std::string& uri) : fd(::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)) {
        CHECK(fd >= 0);
        timeval timeout{3, 0};
        ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        sockaddr_in endpoint{};
        endpoint.sin_family = AF_INET; endpoint.sin_port = htons(address(uri).port);
        endpoint.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (::connect(fd, reinterpret_cast<sockaddr*>(&endpoint), sizeof(endpoint)) != 0) {
            ::close(fd); fd = -1; throw std::runtime_error("Could not connect to fixture relay");
        }
    }
    Socket(const Socket&) = delete;
    ~Socket() { if (fd >= 0) ::close(fd); }
    void send(const std::string& text) {
        size_t at = 0;
        while (at < text.size()) {
            auto n = ::send(fd, text.data() + at, text.size() - at, MSG_NOSIGNAL);
            CHECK(n > 0); at += size_t(n);
        }
    }
    std::string receive(bool headersOnly = false) {
        std::string text;
        while (!headersOnly || text.find("\r\n\r\n") == std::string::npos) {
            char chunk[4096]; auto n = ::recv(fd, chunk, sizeof(chunk), 0);
            if (n == 0 || (n < 0 && errno == ECONNRESET)) break;
            if (n < 0 && errno == EINTR) continue;
            CHECK(n > 0);
            text.append(chunk, size_t(n));
            CHECK(text.size() <= 4 * 1024 * 1024);
        }
        return text;
    }
};
std::string request(const std::string& uri, const std::string& method = "GET", const std::string& headers = "") {
    return method + " " + address(uri).path + " HTTP/1.1\r\nHost: 127.0.0.1\r\n" + headers + "\r\n";
}
struct Response {
    int status = 0;
    std::map<std::string, std::string> headers;
    std::string body;
};
Response response(const std::string& raw) {
    Response r;
    if (raw.empty()) return r;
    auto end = raw.find("\r\n\r\n"); CHECK(end != std::string::npos);
    r.body = raw.substr(end + 4);
    std::istringstream lines(raw.substr(0, end));
    std::string version, line; lines >> version >> r.status; std::getline(lines, line);
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto colon = line.find(':'); CHECK(colon != std::string::npos);
        r.headers.emplace(line.substr(0, colon), line.substr(colon + 2));
    }
    return r;
}
Response transact(const std::string& uri, const std::string& method = "GET", const std::string& headers = "") {
    Socket client(uri); client.send(request(uri, method, headers)); return response(client.receive());
}
std::string token(unsigned n = 1) {
    std::ostringstream s; s << std::hex << std::setw(64) << std::setfill('0') << n; return s.str();
}
struct Media {
    std::string bytes = "0123456789abcdef";
    std::atomic<unsigned> sizes{0}, reads{0}, checks{0};
    std::atomic<bool> allowed{true};
    Relay::Resource resource() {
        return {[this] { ++checks; if (!allowed) throw UserError("Profile access expired"); },
            [this] { ++sizes; return bytes.size(); },
            [this](uint64_t offset, size_t count) {
                ++reads; CHECK(offset <= bytes.size()); CHECK(count <= bytes.size() - offset);
                return Bytes(bytes.begin() + offset, bytes.begin() + offset + count);
            }, "video/x-matroska"};
    }
};
struct Gate {
    std::mutex mutex;
    std::condition_variable changed;
    unsigned entered = 0;
    bool open = false;
    void block() {
        std::unique_lock<std::mutex> lock(mutex); ++entered; changed.notify_all();
        if (!changed.wait_for(lock, 5s, [&] { return open; })) throw UserError("Fixture gate timed out");
    }
    void await(unsigned count = 1) {
        std::unique_lock<std::mutex> lock(mutex);
        CHECK(changed.wait_for(lock, 3s, [&] { return entered >= count; }));
    }
    void release() { std::lock_guard<std::mutex> lock(mutex); open = true; changed.notify_all(); }
};
struct ReleaseGate {
    std::shared_ptr<Gate> gate;
    ~ReleaseGate() { gate->release(); }
};
Relay::Resource delayedResource(const std::shared_ptr<Media>& media, const std::shared_ptr<Gate>& gate, bool size = false) {
    auto resource = media->resource();
    // Keep both fixtures alive until any detached connection worker has exited.
    resource.check = [media] { ++media->checks; if (!media->allowed) throw UserError("Profile access expired"); };
    resource.size = [media, gate, size] { if (size) gate->block(); ++media->sizes; return media->bytes.size(); };
    resource.read = [media, gate, size](uint64_t offset, size_t count) {
        if (!size) gate->block();
        ++media->reads;
        return Bytes(media->bytes.begin() + offset, media->bytes.begin() + offset + count);
    };
    return resource;
}
}

CASE(relay_get_head) {
    Media media; Relay relay; auto uri = relay.add(token(), media.resource());
    auto head = transact(uri, "HEAD");
    CHECK(head.status == 200); CHECK(head.body.empty()); CHECK(media.reads == 0);
    CHECK(head.headers.at("Content-Length") == "16"); CHECK(head.headers.at("Content-Type") == "video/x-matroska");
    CHECK(head.headers.at("Cache-Control") == "no-store"); CHECK(head.headers.at("Accept-Ranges") == "bytes");
    auto get = transact(uri); CHECK(get.status == 200); CHECK(get.body == media.bytes); CHECK(media.reads == 1);
}
CASE(relay_ranges) {
    Media media; Relay relay; auto uri = relay.add(token(), media.resource());
    for (const auto& item : std::vector<std::pair<std::string, std::string>>{
            {"2-5", "2345"}, {"12-", "cdef"}, {"-4", "cdef"}, {"0-99", media.bytes}, {"-99", media.bytes}, {"15-15", "f"}}) {
        auto r = transact(uri, "GET", "Range: bytes=" + item.first + "\r\n");
        CHECK(r.status == 206); CHECK(r.body == item.second); CHECK(r.headers.at("Content-Length") == std::to_string(item.second.size()));
    }
    auto r = transact(uri, "HEAD", "rAnGe: bytes=2-5\r\n");
    CHECK(r.status == 206); CHECK(r.headers.at("Content-Range") == "bytes 2-5/16"); CHECK(r.body.empty());
}
CASE(relay_invalid_ranges) {
    Media media; Relay relay; auto uri = relay.add(token(), media.resource());
    for (const std::string range : {"bytes=16-", "bytes=9-3", "bytes=-0", "bytes=-", "bytes=0-1,4-5", "bytes=abc-5",
            "items=0-1", "bytes=+1-2", "bytes=0-18446744073709551616", "bytes=18446744073709551615-", "bytes=0-1-2"}) {
        auto r = transact(uri, "GET", "Range: " + range + "\r\n");
        CHECK(r.status == 416); CHECK(r.body.empty()); CHECK(r.headers.at("Content-Range") == "bytes */16");
    }
    CHECK(media.reads == 0);
}
CASE(relay_invalid_requests) {
    Media media; Relay relay; auto uri = relay.add(token(), media.resource());
    for (const std::string headers : {"Range: bytes=0-1\r\nRange: bytes=2-3\r\n", "Content-Length: 1\r\n",
            "Transfer-Encoding: chunked\r\n", "Bad header\r\n"}) {
        CHECK(transact(uri, "GET", headers).status == 0);
    }
    CHECK(transact(uri, "POST").status == 0);
    auto other = uri.substr(0, uri.find_last_of('/') + 1) + token(99);
    CHECK(transact(other).status == 0);
    CHECK(transact(uri + "?secret=1").status == 0);
    Socket oversized(uri); oversized.send(request(uri, "GET", "X-Large: " + std::string(9000, 'a') + "\r\n"));
    CHECK(oversized.receive().empty());
    CHECK(media.sizes == 0); CHECK(media.reads == 0);
}
CASE(relay_resource_limits) {
    Media media; Relay relay;
    for (const std::string& mime : std::vector<std::string>{"", "invalid", "video/mkv\r\nX-Injected: yes", "video/mkv\n",
            std::string("video/\0mkv", 10), "video/" + std::string(257, 'a')}) {
        auto resource = media.resource(); resource.mime = mime;
        test::rejected([&] { relay.add(token(), resource); });
    }
    for (const std::string& invalid : std::vector<std::string>{"short", std::string(64, '/'), std::string(64, 'z'), std::string(65, 'a')})
        test::rejected([&] { relay.add(invalid, media.resource()); });
    auto missingCallback = media.resource(); missingCallback.check = {};
    test::rejected([&] { relay.add(token(), missingCallback); });
    for (unsigned i = 0; i < 256; ++i) relay.add(token(i), media.resource());
    test::rejected([&] { relay.add(token(256), media.resource()); });
    relay.revokeAll(); CHECK(transact(relay.add(token(), media.resource()), "HEAD").status == 200);
}
CASE(relay_ticket_isolation) {
    Media first, second; second.bytes = "different"; Relay relay;
    auto one = relay.add(token(1), first.resource()), two = relay.add(token(2), second.resource());
    CHECK(transact(one).body == first.bytes); CHECK(transact(two).body == second.bytes);
    relay.revoke(one); CHECK(transact(one).status == 0); CHECK(transact(two).body == second.bytes);
}
CASE(relay_read_bounds) {
    Media media; Relay relay;
    unsigned sequence = 0;
    for (bool oversized : {false, true}) {
        auto resource = media.resource();
        resource.read = [oversized](uint64_t, size_t n) { return oversized ? Bytes(n + 1, 'x') : Bytes(); };
        auto r = transact(relay.add(token(++sequence), resource)); CHECK(r.status == 200); CHECK(r.body.empty());
    }
    // Short successful reads are legal; chunking must still produce exactly the announced range.
    auto resource = media.resource();
    resource.read = [&media](uint64_t at, size_t n) { n = std::min<size_t>(3, n); return Bytes(media.bytes.begin() + at, media.bytes.begin() + at + n); };
    CHECK(transact(relay.add(token(++sequence), resource)).body == media.bytes);
}
CASE(relay_chunk_bounds) {
    Media media; media.bytes.resize(1024 * 1024 + 13);
    for (size_t n = 0; n < media.bytes.size(); ++n) media.bytes[n] = char(n % 251);
    std::atomic<size_t> largest{0};
    auto resource = media.resource();
    resource.read = [&media, &largest](uint64_t at, size_t count) {
        ++media.reads;
        largest.store(std::max(largest.load(), count));
        CHECK(count <= 512 * 1024); CHECK(at + count <= media.bytes.size());
        return Bytes(media.bytes.begin() + at, media.bytes.begin() + at + count);
    };
    Relay relay; auto uri = relay.add(token(), resource);
    CHECK(transact(uri).body == media.bytes); CHECK(media.reads == 3); CHECK(largest == 512 * 1024);
    auto range = transact(uri, "GET", "Range: bytes=524280-524300\r\n");
    CHECK(range.status == 206); CHECK(range.body == media.bytes.substr(524280, 21));
}
CASE(relay_permission_before_read) {
    Media media; media.allowed = false; Relay relay; auto uri = relay.add(token(), media.resource());
    CHECK(transact(uri).status == 0); CHECK(media.sizes == 0); CHECK(media.reads == 0);
}
CASE(relay_permission_after_size) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Relay relay; auto uri = relay.add(token(), delayedResource(media, gate, true));
    Socket client(uri); client.send(request(uri)); gate->await(); media->allowed = false; gate->release();
    CHECK(client.receive().empty()); CHECK(media->reads == 0);
}
CASE(relay_permission_after_read) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Relay relay; auto uri = relay.add(token(), delayedResource(media, gate));
    Socket client(uri); client.send(request(uri)); auto headers = client.receive(true); gate->await();
    media->allowed = false; gate->release();
    CHECK(response(headers + client.receive()).body.empty()); CHECK(media->reads == 1);
}
CASE(relay_revoke_blocked_read) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Relay relay; auto uri = relay.add(token(), delayedResource(media, gate));
    Socket client(uri); client.send(request(uri)); auto headers = client.receive(true); gate->await();
    relay.revoke(uri); gate->release();
    CHECK(response(headers + client.receive()).body.empty()); CHECK(transact(uri).status == 0);
}
CASE(relay_replace_blocked_read) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Media replacement; replacement.bytes = "new session"; Relay relay;
    auto uri = relay.add(token(), delayedResource(media, gate));
    Socket client(uri); client.send(request(uri)); auto headers = client.receive(true); gate->await();
    test::rejected([&] { relay.add(token(), replacement.resource()); });
    relay.revoke(uri); relay.add(token(), replacement.resource()); gate->release();
    CHECK(response(headers + client.receive()).body.empty()); CHECK(transact(uri).body == replacement.bytes);
}
CASE(relay_revoke_all) {
    Media media; Relay relay;
    auto one = relay.add(token(1), media.resource()), two = relay.add(token(2), media.resource());
    relay.revokeAll(); CHECK(transact(one).status == 0); CHECK(transact(two).status == 0); CHECK(media.reads == 0);
}
CASE(relay_client_limit) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Relay relay; auto uri = relay.add(token(), delayedResource(media, gate));
    std::vector<std::unique_ptr<Socket>> clients;
    for (unsigned i = 0; i < 8; ++i) {
        clients.push_back(std::make_unique<Socket>(uri)); clients.back()->send(request(uri));
        CHECK(response(clients.back()->receive(true)).status == 200);
    }
    gate->await(8); CHECK(transact(uri, "HEAD").status == 0); CHECK(media->sizes == 8);
    gate->release(); for (auto& client : clients) CHECK(client->receive() == media->bytes);
}
CASE(relay_stop) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    auto relay = std::make_unique<Relay>(); auto uri = relay->add(token(), delayedResource(media, gate));
    Socket client(uri); client.send(request(uri)); auto headers = client.receive(true); gate->await();
    relay.reset(); gate->release(); CHECK(response(headers + client.receive()).body.empty());
}
CASE(relay_header_deadline) {
    Media media; Relay relay; auto uri = relay.add(token(), media.resource());
    Socket client(uri);
    auto started = std::chrono::steady_clock::now();
    bool closed = false;
    // A byte every quarter-second keeps per-recv timeouts alive. The relay must
    // still enforce one deadline for the whole unauthenticated request header.
    while (std::chrono::steady_clock::now() - started < 7s) {
        auto sent = ::send(client.fd, "G", 1, MSG_NOSIGNAL);
        if (sent < 0 && (errno == EPIPE || errno == ECONNRESET)) { closed = true; break; }
        CHECK(sent == 1);
        pollfd event{client.fd, POLLIN | POLLHUP, 0};
        auto ready = ::poll(&event, 1, 250); CHECK(ready >= 0);
        if (ready > 0) {
            char byte; auto got = ::recv(client.fd, &byte, 1, 0);
            CHECK(got == 0 || (got < 0 && errno == ECONNRESET));
            closed = true; break;
        }
    }
    auto elapsed = std::chrono::steady_clock::now() - started;
    CHECK(closed); CHECK(elapsed >= 4s); CHECK(elapsed < 7s);
    CHECK(media.sizes == 0); CHECK(media.reads == 0); CHECK(media.checks == 0);
}

#if defined(MEDIAVAULT_RELAY_TRACE_TEST)
namespace {
std::mutex traceMutex;
std::condition_variable traceChanged;
std::vector<std::string> traceRecords;
using TraceRecord = std::map<std::string, std::string>;
std::vector<TraceRecord> records(size_t count) {
    std::unique_lock<std::mutex> lock(traceMutex);
    CHECK(traceChanged.wait_for(lock, 3s, [&] { return traceRecords.size() >= count; }));
    std::vector<TraceRecord> result;
    // A complete allowlist, not a blacklist: paths, headers, MIME values, body
    // contents and exception messages cannot appear anywhere in a record.
    const std::regex schema(R"(^MV_FIXTURE_RELAY_V1 event=(response|finish) request=[0-9]+ resource=[0-9]+ monotonicMs=[0-9]+ elapsedMs=[0-9]+ method=(GET|HEAD|unknown) range=[01] start=[0-9]+ endExclusive=[0-9]+ total=[0-9]+ status=(0|200|206|416) length=[0-9]+ sent=[0-9]+ stage=(parse|access|size|read|send|complete)$)");
    for (const auto &line : traceRecords) {
        CHECK(std::regex_match(line, schema));
        std::istringstream words(line); std::string item; words >> item;
        TraceRecord record;
        while (words >> item) { auto equals = item.find('='); record[item.substr(0, equals)] = item.substr(equals + 1); }
        result.push_back(std::move(record));
    }
    return result;
}
void completed(const TraceRecord &record, unsigned status, uint64_t start, uint64_t end,
               uint64_t total, uint64_t sent, const std::string &method = "GET") {
    CHECK(record.at("event") == "finish"); CHECK(record.at("stage") == "complete");
    CHECK(record.at("status") == std::to_string(status)); CHECK(record.at("method") == method);
    CHECK(record.at("start") == std::to_string(start)); CHECK(record.at("endExclusive") == std::to_string(end));
    CHECK(record.at("total") == std::to_string(total)); CHECK(record.at("length") == std::to_string(end - start));
    CHECK(record.at("sent") == std::to_string(sent)); CHECK(record.at("resource") != "0");
}
}
namespace mediavault {
void writeFixtureRelayTrace(const std::string &message) noexcept {
    std::lock_guard<std::mutex> lock(traceMutex);
    traceRecords.push_back(message); traceChanged.notify_all();
}
}
CASE(fixture_relay_trace_ranges) {
    Media media; Relay relay; const auto uri = relay.add(token(), media.resource());
    CHECK(transact(uri).body == media.bytes);
    CHECK(transact(uri, "HEAD").body.empty());
    CHECK(transact(uri, "GET", "Range: bytes=2-5\r\n").body == "2345");
    CHECK(transact(uri, "GET", "Range: bytes=12-\r\n").body == "cdef");
    CHECK(transact(uri, "GET", "Range: bytes=-4\r\n").body == "cdef");
    CHECK(transact(uri, "GET", "Range: bytes=16-\r\n").status == 416);
    const auto log = records(12); CHECK(log.size() == 12);
    completed(log[1], 200, 0, 16, 16, 16);
    completed(log[3], 200, 0, 16, 16, 0, "HEAD");
    completed(log[5], 206, 2, 6, 16, 4);
    completed(log[7], 206, 12, 16, 16, 4);
    completed(log[9], 206, 12, 16, 16, 4);
    completed(log[11], 416, 0, 0, 16, 0);
    for (size_t i = 0; i < log.size(); i += 2) {
        CHECK(log[i].at("event") == "response"); CHECK(log[i].at("sent") == "0");
        CHECK(log[i].at("request") == log[i + 1].at("request"));
        CHECK(log[i].at("resource") == log[0].at("resource"));
        CHECK(log[i].at("range") == (i < 4 ? "0" : "1"));
    }
}
CASE(fixture_relay_trace_short_read) {
    Media media; Relay relay; auto resource = media.resource();
    resource.read = [&media](uint64_t at, size_t n) {
        n = std::min<size_t>(3, n); return Bytes(media.bytes.begin() + at, media.bytes.begin() + at + n);
    };
    CHECK(transact(relay.add(token(), resource)).body == media.bytes);
    resource.read = [](uint64_t at, size_t) { return at == 0 ? Bytes(3, 'x') : Bytes(); };
    CHECK(transact(relay.add(token(2), resource)).body == "xxx");
    const auto log = records(4); completed(log[1], 200, 0, 16, 16, 16);
    CHECK(log[3].at("stage") == "read"); CHECK(log[3].at("sent") == "3");
    CHECK(log[3].at("length") == "16"); CHECK(log[1].at("resource") != log[3].at("resource"));
}
CASE(fixture_relay_trace_private_errors) {
    Media media; media.bytes = "BODY_PRIVATE_SENTINEL"; Relay relay;
    auto resource = media.resource(); resource.mime = "video/MIME_PRIVATE_SENTINEL";
    const auto uri = relay.add(std::string(64, 'a'), resource);
    CHECK(transact(uri, "POST", "X-Secret: HEADER_PRIVATE_SENTINEL\r\n").status == 0);
    CHECK(transact(uri, "GET", "Range: RANGE_PRIVATE_SENTINEL\r\n").status == 416);
    resource.read = [](uint64_t, size_t) -> Bytes { throw UserError("EXCEPTION_PRIVATE_SENTINEL"); };
    CHECK(transact(relay.add(token(2), resource)).body.empty());
    resource.check = [] { throw UserError("ACCESS_PRIVATE_SENTINEL"); };
    CHECK(transact(relay.add(token(3), resource)).status == 0);
    const auto log = records(5); CHECK(log.size() == 5);
    CHECK(log[1].at("status") == "416"); CHECK(log[3].at("stage") == "read");
    CHECK(log[4].at("stage") == "access"); CHECK(log[4].at("sent") == "0");
}
CASE(fixture_relay_trace_peer_close) {
    auto media = std::make_shared<Media>(); auto gate = std::make_shared<Gate>(); ReleaseGate release{gate};
    Relay relay; const auto uri = relay.add(token(), delayedResource(media, gate));
    Socket client(uri); client.send(request(uri)); CHECK(response(client.receive(true)).status == 200); gate->await();
    linger reset{1, 0}; CHECK(::setsockopt(client.fd, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset)) == 0);
    CHECK(::close(client.fd) == 0); client.fd = -1; gate->release();
    const auto log = records(2);
    CHECK(log[1].at("event") == "finish"); CHECK(log[1].at("stage") == "send");
    CHECK(log[1].at("length") == "16"); CHECK(log[1].at("sent") == "0");
}
CASE(fixture_relay_trace_cap) {
    Media media; Relay relay; const auto uri = relay.add(token(), media.resource());
    auto artwork = media.resource(); artwork.mime = "image/png";
    const auto artworkURI = relay.add(token(2), artwork);
    // Earlier screen artwork must not consume the media diagnostic budget.
    for (unsigned i = 0; i < 70; ++i) CHECK(transact(artworkURI).body == media.bytes);
    for (unsigned i = 0; i < 70; ++i) CHECK(transact(uri, "HEAD").status == 200);
    const auto log = records(128); CHECK(log.size() == 128);
    for (size_t i = 0; i < log.size(); i += 2) {
        CHECK(log[i].at("request") == std::to_string(i / 2 + 1));
        completed(log[i + 1], 200, 0, 16, 16, 0, "HEAD");
    }
}
#endif
