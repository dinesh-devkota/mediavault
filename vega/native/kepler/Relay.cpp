#include "Relay.h"
#include <algorithm>
#include <arpa/inet.h>
#include <chrono>
#include <limits>
#include <set>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>

namespace mediavault {
struct Relay::State : std::enable_shared_from_this<State> {
  int socket = -1;
  uint16_t port = 0;
  std::mutex mutex;
  bool stopped = false;
  std::map<std::string, std::shared_ptr<Resource>> resources;
  std::map<int, std::string> clients;
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
                 const uint8_t *bytes, size_t count) {
    while (count) {
      check(token, resource);
      auto result =
          ::send(fd, bytes, std::min<size_t>(count, 16384), MSG_NOSIGNAL);
      if (result <= 0)
        throw UserError("Playback connection closed.");
      bytes += result;
      count -= size_t(result);
    }
  }
  void serve(int fd) {
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
          range = value;
        }
        if (name == "transfer-encoding" ||
            (name == "content-length" && value != "0"))
          throw UserError("Playback request bodies are unsupported.");
      }
      std::shared_ptr<Resource> resource;
      {
        std::lock_guard<std::mutex> lock(mutex);
        auto entry = resources.find(token);
        if (entry == resources.end() || stopped)
          throw UserError("Unknown playback resource.");
        resource = entry->second;
        clients[fd] = token;
      }
      check(token, resource);
      auto total = resource->size();
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
                headers.size());
      if (valid && method == "GET")
        while (start < finish) {
          check(token, resource);
          size_t count = size_t(std::min<uint64_t>(512 * 1024, finish - start));
          auto bytes = resource->read(start, count);
          check(token, resource);
          if (bytes.empty() || bytes.size() > count)
            throw UserError("Unexpected end of media.");
          sendBytes(fd, token, resource, bytes.data(), bytes.size());
          start += bytes.size();
        }
    } catch (
        ...) { /* Never put source URLs or credentials into client errors. */
    }
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
  return "http://127.0.0.1:" + std::to_string(state->port) + "/" + token;
}
void Relay::revoke(const std::string &uri) {
  auto token = uri.substr(uri.find_last_of('/') + 1);
  std::lock_guard<std::mutex> lock(state->mutex);
  state->resources.erase(token);
  for (const auto &pair : state->clients)
    if (pair.second == token)
      ::shutdown(pair.first, SHUT_RDWR);
}
void Relay::revokeAll() {
  std::lock_guard<std::mutex> lock(state->mutex);
  state->resources.clear();
  for (const auto &pair : state->clients)
    ::shutdown(pair.first, SHUT_RDWR);
}
} // namespace mediavault
