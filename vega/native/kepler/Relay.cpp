#include "Relay.h"
#include <algorithm>
#include <arpa/inet.h>
#include <chrono>
#include <limits>
#include <set>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

#if defined(MEDIAVAULT_VVD_FIXTURE)
#if !defined(MEDIAVAULT_RELAY_TRACE_TEST)
#include <apmf/iface/com/amazon/apmf/ILogger.h>
#include <apmf/iface/com/amazon/apmf/LogLevel.h>
#include <apmf/process.h>
#endif
#define MV_FIXTURE_TRACE(...) __VA_ARGS__
#else
#define MV_FIXTURE_TRACE(...)
#endif

namespace mediavault {
#if defined(MEDIAVAULT_VVD_FIXTURE)
#if defined(MEDIAVAULT_RELAY_TRACE_TEST)
// Host tests capture exactly the fixture records without the device-only SDK.
void writeFixtureRelayTrace(const std::string &message) noexcept;
#else
void writeFixtureRelayTrace(const std::string &message) noexcept {
  try {
    using namespace apmf::iface::com::amazon::apmf;
    // https://developer.amazon.com/docs/vega-native-api/2.0/interfaces.ILogger.com_amazon_apmf
    // Never attach an SDK error: it can contain source/credential details.
    apmf::GetProcessObject().QueryInterface<ILogger>()
        ->getChild("mediavault.fixture.relay")->log(LogLevel::INFO, message, nullptr);
  } catch (...) { /* Diagnostics must not change transport behavior. */ }
}
#endif
namespace {
std::atomic<uint64_t> fixtureRequests{0}, fixtureResources{0};
enum class TraceMethod { Unknown, Get, Head };
enum class TraceStage { Parse, Access, Size, Read, Send, Complete };
struct FixtureRelayTrace {
  // At most two records for each of the first 64 video/audio requests.
  // Artwork/photo requests cannot exhaust the budget before playback starts.
  // Everything retained is an ordinal, a number, or a fixed allowlisted label.
  uint64_t request = 0;
  const std::chrono::steady_clock::time_point began = std::chrono::steady_clock::now();
  uint64_t resource = 0, start = 0, endExclusive = 0, total = 0, length = 0, sent = 0;
  unsigned status = 0;
  bool range = false;
  TraceMethod method = TraceMethod::Unknown;
  TraceStage stage = TraceStage::Parse;
  void emit(bool finished) const noexcept {
    if (!request || request > 64) return;
    try {
      const auto now = std::chrono::steady_clock::now();
      const char *stageName = "parse";
      switch (stage) {
      case TraceStage::Parse: break;
      case TraceStage::Access: stageName = "access"; break;
      case TraceStage::Size: stageName = "size"; break;
      case TraceStage::Read: stageName = "read"; break;
      case TraceStage::Send: stageName = "send"; break;
      case TraceStage::Complete: stageName = "complete"; break;
      }
      std::ostringstream record;
      record << "MV_FIXTURE_RELAY_V1 event=" << (finished ? "finish" : "response")
             << " request=" << request << " resource=" << resource
             << " monotonicMs=" << std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count()
             << " elapsedMs=" << std::chrono::duration_cast<std::chrono::milliseconds>(now - began).count()
             << " method=" << (method == TraceMethod::Get ? "GET" : method == TraceMethod::Head ? "HEAD" : "unknown")
             << " range=" << range << " start=" << start << " endExclusive=" << endExclusive
             << " total=" << total << " status=" << status << " length=" << length
             << " sent=" << sent << " stage=" << stageName;
      writeFixtureRelayTrace(record.str());
    } catch (...) { /* No exception text is ever logged. */ }
  }
};
} // namespace
#endif
struct Relay::State : std::enable_shared_from_this<State> {
  int socket = -1;
  uint16_t port = 0;
  std::mutex mutex;
  bool stopped = false;
  std::map<std::string, std::shared_ptr<Resource>> resources;
  std::map<int, std::string> clients;
  MV_FIXTURE_TRACE(std::map<std::string, uint64_t> resourceOrdinals;)
  void check(const std::string &token,
             const std::shared_ptr<Resource> &resource) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      auto entry = resources.find(token);
      if (stopped || entry == resources.end() || entry->second != resource)
        throw UserError("Playback access expired.");
    }
    resource->check();
  }
  void sendBytes(int fd, const std::string &token,
                 const std::shared_ptr<Resource> &resource,
                 const uint8_t *bytes, size_t count
#if defined(MEDIAVAULT_VVD_FIXTURE)
                 , FixtureRelayTrace &trace, bool body
#endif
                 ) {
    while (count) {
      MV_FIXTURE_TRACE(trace.stage = TraceStage::Access;)
      check(token, resource);
      MV_FIXTURE_TRACE(trace.stage = TraceStage::Send;)
      auto result =
          ::send(fd, bytes, std::min<size_t>(count, 16384), MSG_NOSIGNAL);
      if (result <= 0)
        throw UserError("Playback connection closed.");
      MV_FIXTURE_TRACE(if (body) trace.sent += uint64_t(result);)
      bytes += result;
      count -= size_t(result);
    }
  }
  void serve(int fd) {
    MV_FIXTURE_TRACE(FixtureRelayTrace trace;)
    try {
      std::string input;
      input.reserve(8192);
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
      while (input.find("\r\n\r\n") == std::string::npos) {
        // Apply one deadline to the whole header, not a fresh five seconds
        // after every byte from an unauthenticated local client.
        const auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) throw UserError("Playback request timed out.");
        timeval timeout{static_cast<time_t>(remaining / 1000000),
                        static_cast<suseconds_t>(remaining % 1000000)};
        if (::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0)
          throw UserError("Could not bound the playback request.");
        char chunk[1024];
        auto got = ::recv(
            fd, chunk, std::min<size_t>(sizeof(chunk), 8192 - input.size()), 0);
        if (got <= 0 || input.size() + size_t(got) > 8192 ||
            std::chrono::steady_clock::now() >= deadline)
          throw UserError("Invalid playback request.");
        input.append(chunk, size_t(got));
      }
      auto end = input.find("\r\n\r\n");
      if (end + 4 != input.size())
        throw UserError("Playback requests cannot contain a body.");
      std::istringstream lines(input);
      std::string line, method, path, version;
      std::getline(lines, line);
      std::istringstream first(line);
      first >> method >> path >> version;
      if ((method != "GET" && method != "HEAD") ||
          (version != "HTTP/1.1" && version != "HTTP/1.0") ||
          path.size() != 65 || path.front() != '/')
        throw UserError("Invalid playback request.");
      MV_FIXTURE_TRACE(trace.method = method == "GET" ? TraceMethod::Get : TraceMethod::Head;)
      std::string token = path.substr(1), range;
      bool hasRange = false;
      while (std::getline(lines, line) && line != "\r") {
        auto colon = line.find(':');
        if (colon == std::string::npos)
          throw UserError("Invalid request header.");
        auto name = line.substr(0, colon), value = line.substr(colon + 1);
        std::transform(name.begin(), name.end(), name.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        while (!value.empty() &&
               std::isspace(static_cast<unsigned char>(value.back())))
          value.pop_back();
        value.erase(0, value.find_first_not_of(" \t"));
        if (name == "range") {
          if (hasRange)
            throw UserError("Duplicate range.");
          hasRange = true;
          MV_FIXTURE_TRACE(trace.range = true;)
          range = value;
        }
        if (name == "transfer-encoding" ||
            (name == "content-length" && value != "0"))
          throw UserError("Playback request bodies are unsupported.");
      }
      MV_FIXTURE_TRACE(trace.stage = TraceStage::Access;)
      std::shared_ptr<Resource> resource;
      {
        std::lock_guard<std::mutex> lock(mutex);
        auto entry = resources.find(token);
        if (entry == resources.end() || stopped)
          throw UserError("Unknown playback resource.");
        resource = entry->second;
        MV_FIXTURE_TRACE(
          auto ordinal = resourceOrdinals.find(token);
          if (ordinal != resourceOrdinals.end()) {
            trace.resource = ordinal->second;
            trace.request = ++fixtureRequests;
          }
        )
        clients[fd] = token;
      }
      check(token, resource);
      MV_FIXTURE_TRACE(trace.stage = TraceStage::Size;)
      auto total = resource->size();
      MV_FIXTURE_TRACE(trace.total = total; trace.stage = TraceStage::Access;)
      check(token, resource);
      uint64_t start = 0, finish = total;
      bool valid = total > 0;
      auto integer = [](const std::string &value) -> uint64_t {
        if (value.empty() ||
            !std::all_of(value.begin(), value.end(),
                         [](unsigned char c) { return c >= '0' && c <= '9'; }))
          throw UserError("Invalid range.");
        size_t used = 0;
        auto number = std::stoull(value, &used);
        if (used != value.size())
          throw UserError("Invalid range.");
        return number;
      };
      if (hasRange)
        try {
          if (range.compare(0, 6, "bytes=") != 0 ||
              range.find(',') != std::string::npos)
            throw UserError("Invalid range.");
          auto dash = range.find('-', 6);
          if (dash == std::string::npos)
            throw UserError("Invalid range.");
          auto left = range.substr(6, dash - 6), right = range.substr(dash + 1);
          if (left.empty()) {
            auto suffix = integer(right);
            if (!suffix)
              throw UserError("Invalid range.");
            start = total - std::min(total, suffix);
          } else {
            start = integer(left);
            if (!right.empty()) {
              auto last = integer(right);
              if (last < start)
                throw UserError("Invalid range.");
              finish = last >= total - 1 ? total : last + 1;
            }
          }
          valid = total > 0 && start < total && finish > start;
        } catch (...) {
          valid = false;
        }
      MV_FIXTURE_TRACE(
        trace.start = valid ? start : 0; trace.endExclusive = valid ? finish : 0;
        trace.length = valid ? finish - start : 0;
        trace.status = valid ? (hasRange ? 206 : 200) : 416;
        trace.stage = TraceStage::Send;
        trace.emit(false);
      )
      std::string headers;
      if (!valid)
        headers =
            "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */" +
            std::to_string(total) + "\r\nContent-Length: 0\r\n";
      else {
        headers = hasRange ? "HTTP/1.1 206 Partial Content\r\n"
                           : "HTTP/1.1 200 OK\r\n";
        headers += "Content-Length: " + std::to_string(finish - start) +
                   "\r\nContent-Type: " + resource->mime +
                   "\r\nAccept-Ranges: bytes\r\n";
        if (hasRange)
          headers += "Content-Range: bytes " + std::to_string(start) + "-" +
                     std::to_string(finish - 1) + "/" + std::to_string(total) +
                     "\r\n";
      }
      headers += "Connection: close\r\nCache-Control: no-store\r\n\r\n";
      sendBytes(fd, token, resource,
                reinterpret_cast<const uint8_t *>(headers.data()),
                headers.size()
#if defined(MEDIAVAULT_VVD_FIXTURE)
                , trace, false
#endif
                );
      if (valid && method == "GET")
        while (start < finish) {
          MV_FIXTURE_TRACE(trace.stage = TraceStage::Access;)
          check(token, resource);
          size_t count = size_t(std::min<uint64_t>(512 * 1024, finish - start));
          MV_FIXTURE_TRACE(trace.stage = TraceStage::Read;)
          auto bytes = resource->read(start, count);
          MV_FIXTURE_TRACE(trace.stage = TraceStage::Access;)
          check(token, resource);
          MV_FIXTURE_TRACE(trace.stage = TraceStage::Read;)
          if (bytes.empty() || bytes.size() > count)
            throw UserError("Unexpected end of media.");
          sendBytes(fd, token, resource, bytes.data(), bytes.size()
#if defined(MEDIAVAULT_VVD_FIXTURE)
                    , trace, true
#endif
                    );
          start += bytes.size();
        }
      MV_FIXTURE_TRACE(trace.stage = TraceStage::Complete;)
    } catch (
        ...) { /* Never put source URLs or credentials into client errors. */
    }
    MV_FIXTURE_TRACE(trace.emit(true);)
    {
      std::lock_guard<std::mutex> lock(mutex);
      clients.erase(fd);
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
  }
};
Relay::Relay() : state(std::make_shared<State>()) {
  state->socket = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (state->socket < 0)
    throw UserError("Could not start local playback.");
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (::bind(state->socket, reinterpret_cast<sockaddr *>(&address),
             sizeof(address)) < 0 ||
      ::listen(state->socket, 8) < 0) {
    ::close(state->socket);
    throw UserError("Could not start local playback.");
  }
  socklen_t length = sizeof(address);
  ::getsockname(state->socket, reinterpret_cast<sockaddr *>(&address), &length);
  state->port = ntohs(address.sin_port);
  listener = std::thread([s = state] {
    while (true) {
      int fd = ::accept4(s->socket, nullptr, nullptr, SOCK_CLOEXEC);
      if (fd < 0)
        break;
      timeval timeout{5, 0};
      ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
      ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
      {
        std::lock_guard<std::mutex> lock(s->mutex);
        if (s->stopped || s->clients.size() >= 8) {
          ::close(fd);
          continue;
        }
        s->clients[fd] = "";
      }
      std::thread([s, fd] { s->serve(fd); }).detach();
    }
  });
}
Relay::~Relay() {
  revokeAll();
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->stopped = true;
  }
  ::shutdown(state->socket, SHUT_RDWR);
  ::close(state->socket);
  if (listener.joinable())
    listener.join();
}
std::string Relay::add(const std::string &token, Resource resource) {
  if (token.size() != 64 ||
      !std::all_of(token.begin(), token.end(), [](unsigned char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
               (c >= 'A' && c <= 'F');
      }))
    throw UserError("Invalid playback capability.");
  if (resource.mime.empty() || resource.mime.size() > 256 ||
      resource.mime.find('/') == std::string::npos ||
      std::any_of(resource.mime.begin(), resource.mime.end(),
                  [](unsigned char c) { return c < 32 || c > 126; }))
    throw UserError("Invalid media content type.");
  if (!resource.check || !resource.size || !resource.read)
    throw UserError("Invalid media provider.");
  std::lock_guard<std::mutex> lock(state->mutex);
  if (state->resources.size() >= 256)
    throw UserError("Close unused media previews and try again.");
  if (state->resources.count(token))
    throw UserError("Playback capability already exists.");
  state->resources[token] = std::make_shared<Resource>(std::move(resource));
  MV_FIXTURE_TRACE(
    const auto &mime = state->resources[token]->mime;
    if (mime.compare(0, 6, "video/") == 0 || mime.compare(0, 6, "audio/") == 0)
      state->resourceOrdinals[token] = ++fixtureResources;
  )
  return "http://127.0.0.1:" + std::to_string(state->port) + "/" + token;
}
void Relay::revoke(const std::string &uri) {
  auto token = uri.substr(uri.find_last_of('/') + 1);
  std::lock_guard<std::mutex> lock(state->mutex);
  state->resources.erase(token);
  MV_FIXTURE_TRACE(state->resourceOrdinals.erase(token);)
  for (const auto &pair : state->clients)
    if (pair.second == token)
      ::shutdown(pair.first, SHUT_RDWR);
}
void Relay::revokeAll() {
  std::lock_guard<std::mutex> lock(state->mutex);
  state->resources.clear();
  MV_FIXTURE_TRACE(state->resourceOrdinals.clear();)
  for (const auto &pair : state->clients)
    ::shutdown(pair.first, SHUT_RDWR);
}
} // namespace mediavault
