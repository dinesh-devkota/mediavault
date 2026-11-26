#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <stdexcept>
#include <string>
#include <vector>

namespace mediavault {
using JSON = nlohmann::json;
using Bytes = std::vector<uint8_t>;
class UserError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};
class ResponseLimitError : public UserError {
public:
  using UserError::UserError;
};
std::string safeID(const std::string &value);
std::string safePath(const std::string &value);
bool contains(const std::string &path, const std::string &root,
              bool includeRoot = true);
std::string base64(const Bytes &bytes);
Bytes unbase64(const std::string &text);
std::string percentEncode(const std::string &text, bool keepSlash = false);

class Vault {
public:
  Vault();
  ~Vault();
  JSON read(const std::string &id);
  void write(
      const std::string &id, const JSON &value,
      const std::function<void()> &assertCurrent = [] {});
  void remove(const std::string &id);
  Bytes random(size_t length);

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};

struct Source {
  std::string id, kind, endpoint, root, username, password, token, userID;
  uint64_t revision = 0;
  std::vector<std::string> ignoredFolders, ignoredFiles;
  JSON serialized() const;
  static Source parse(const JSON &json);
  void authorize(const std::string &path, bool listing = false) const;
  void authorizeJellyfinCatalog(const std::string &path,
                                const std::string &method,
                                const JSON &query) const;
  void authorizeJellyfinResource(const std::string &path, bool image,
                                 const JSON &query) const;
};

struct HTTPResult {
  int status;
  Bytes body;
  std::map<std::string, std::string> headers;
};
HTTPResult http(const Source &source, const JSON &request,
                const std::function<void()> &assertCurrent);
std::string textResponse(const HTTPResult &result);
class SMB {
public:
  explicit SMB(
      const Source &source, const std::function<void()> &assertCurrent = [] {});
  ~SMB();
  JSON list(const std::string &path);
  JSON stat(const std::string &path);
  Bytes read(const std::string &path, uint64_t offset, size_t length);

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};

class Backend : public std::enable_shared_from_this<Backend> {
public:
  Backend();
  ~Backend();
  std::atomic<uint64_t> generation{1};
  std::atomic<unsigned> activeOperations{0};
  std::string configure(const std::string &sourceJSON, std::string username,
                        std::string password, bool jellyfin, uint64_t epoch);
  void removeSource(const std::string &id, uint64_t epoch);
  void updateSource(const std::string &json, uint64_t epoch);
  std::string list(const std::string &id, const std::string &path,
                   uint64_t epoch);
  std::string stat(const std::string &id, const std::string &path,
                   uint64_t epoch);
  std::string read(const std::string &id, const std::string &path,
                   const std::string &offset, double length, uint64_t epoch);
  std::string request(const std::string &id, const std::string &json,
                      uint64_t epoch);
  std::string ticket(const std::string &id, const std::string &path,
                     const std::string &queryJSON, uint64_t epoch);
  std::string imageTicket(const std::string &id, const std::string &path,
                          const std::string &queryJSON, uint64_t epoch);
  void revoke();
  void revokeResource(const std::string &uri);
  bool hasPIN(const std::string &id, uint64_t epoch);
  void setPIN(const std::string &id, std::string pin, uint64_t epoch);
  bool verifyPIN(const std::string &id, std::string pin, uint64_t epoch);
  void removePIN(const std::string &id, uint64_t epoch);

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};
} // namespace mediavault
