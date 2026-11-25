#include "Core.h"
#include <cerrno>
#include <chrono>
#include <curl/curl.h>
#include <fcntl.h>
#include <poll.h>
// libsmb2.h uses types declared by smb2.h.
// clang-format off
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
// clang-format on
#include <stdexcept>

namespace mediavault {
namespace {
std::string component(CURLU *url, CURLUPart part, unsigned flags = 0) {
  char *raw = nullptr;
  if (curl_url_get(url, part, &raw, flags))
    return {};
  std::string value(raw);
  curl_free(raw);
  return value;
}
} // namespace
struct SMB::Impl {
  smb2_context *ctx = nullptr;
  bool connected = false;
  int connectionStatus = -1;
  std::mutex mutex;
  ~Impl() {
    if (ctx)
      smb2_destroy_context(ctx);
  }
  smb2_stat_64 info(const std::string &path) {
    safePath(path);
    // Do not traverse server symlinks/reparse links out of the selected tree.
    size_t at = 0;
    do {
      at = path.find('/', at);
      const auto prefix = path.substr(0, at);
      smb2_stat_64 value{};
      if (smb2_stat(ctx, prefix.c_str(), &value) != 0)
        throw UserError("The NAS file or folder is unavailable.");
      if (value.smb2_type == SMB2_TYPE_LINK)
        throw UserError("Linked NAS folders are not followed.");
      if (at == std::string::npos)
        return value;
      ++at;
    } while (true);
  }
};
SMB::SMB(const Source &source, const std::function<void()> &assertCurrent)
    : impl(std::make_unique<Impl>()) {
  assertCurrent();
  std::unique_ptr<CURLU, decltype(&curl_url_cleanup)> url(curl_url(),
                                                          curl_url_cleanup);
  if (!url ||
      curl_url_set(url.get(), CURLUPART_URL, source.endpoint.c_str(),
                   CURLU_NON_SUPPORT_SCHEME) ||
      component(url.get(), CURLUPART_SCHEME) != "smb" ||
      !component(url.get(), CURLUPART_USER).empty() ||
      !component(url.get(), CURLUPART_PASSWORD).empty() ||
      !component(url.get(), CURLUPART_QUERY).empty() ||
      !component(url.get(), CURLUPART_FRAGMENT).empty())
    throw UserError("Use smb://server/share without embedded credentials.");
  auto host = component(url.get(), CURLUPART_HOST),
       port = component(url.get(), CURLUPART_PORT);
  auto share = component(url.get(), CURLUPART_PATH, CURLU_URLDECODE);
  if (!share.empty() && share.front() == '/')
    share.erase(0, 1);
  if (!share.empty() && share.back() == '/')
    share.pop_back();
  safePath(share);
  if (host.empty() || share.empty() || share.find('/') != std::string::npos)
    throw UserError("Enter the NAS share separately from its selected folder.");
  if (!port.empty())
    host += ":" + port;
  impl->ctx = smb2_init_context();
  if (!impl->ctx)
    throw UserError("Could not start the NAS connection.");
  smb2_set_timeout(impl->ctx, 10);
  smb2_set_version(impl->ctx, SMB2_VERSION_ANY);
  smb2_set_sign(impl->ctx, 1);
  smb2_set_user(impl->ctx, source.username.c_str());
  smb2_set_password(impl->ctx, source.password.c_str());
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(10);
  const auto complete = [](smb2_context *, int status, void *, void *opaque) {
    auto &state = *static_cast<Impl *>(opaque);
    state.connectionStatus = status;
    state.connected = true;
  };
  if (smb2_connect_share_async(impl->ctx, host.c_str(), share.c_str(),
                               source.username.c_str(), complete,
                               impl.get()) != 0)
    throw UserError(
        "Could not connect to this NAS. Check the address, share and sign-in.");
  // The upstream synchronous waiter can remain in poll after rejected
  // authentication without an outstanding PDU to expire. Own the whole
  // connection deadline and service cancellation between short polls.
  while (!impl->connected) {
    assertCurrent();
    if (std::chrono::steady_clock::now() >= deadline)
      throw UserError("The NAS sign-in timed out. Check the address, share and "
                      "credentials.");
    pollfd descriptor{smb2_get_fd(impl->ctx),
                      static_cast<short>(smb2_which_events(impl->ctx)), 0};
    if (::poll(&descriptor, 1, 100) < 0) {
      if (errno == EINTR)
        continue;
      throw UserError("The NAS connection could not be checked.");
    }
    assertCurrent();
    if (smb2_service(impl->ctx, descriptor.revents) < 0)
      throw UserError(
          "The NAS connection was rejected. Check the share and sign-in.");
  }
  assertCurrent();
  if (impl->connectionStatus != 0)
    throw UserError(
        "The NAS rejected this sign-in or share. Check your credentials.");
}
SMB::~SMB() = default;
JSON SMB::list(const std::string &path) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->info(path).smb2_type != SMB2_TYPE_DIRECTORY)
    throw UserError("Choose a NAS folder.");
  auto raw = smb2_opendir(impl->ctx, path.c_str());
  if (!raw)
    throw UserError("This NAS folder could not be opened.");
  auto close = [this](smb2dir *value) { smb2_closedir(impl->ctx, value); };
  std::unique_ptr<smb2dir, decltype(close)> dir(raw, close);
  JSON result = JSON::array();
  while (auto item = smb2_readdir(impl->ctx, dir.get())) {
    std::string name(item->name);
    if (name == "." || name == ".." || item->st.smb2_type == SMB2_TYPE_LINK)
      continue;
    if (name.find('/') != std::string::npos)
      continue;
    auto child = safePath(path.empty() ? name : path + "/" + name);
    if (result.size() >= 10000)
      throw UserError(
          "This folder has too many entries. Select a smaller media folder.");
    result.push_back({{"path", child},
                      {"name", name},
                      {"directory", item->st.smb2_type == SMB2_TYPE_DIRECTORY},
                      {"size", item->st.smb2_size}});
  }
  return result;
}
JSON SMB::stat(const std::string &path) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  auto value = impl->info(path);
  return {{"size", value.smb2_size},
          {"directory", value.smb2_type == SMB2_TYPE_DIRECTORY}};
}
Bytes SMB::read(const std::string &path, uint64_t offset, size_t length) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  auto value = impl->info(path);
  if (value.smb2_type != SMB2_TYPE_FILE || offset > value.smb2_size ||
      length > 1024 * 1024)
    throw UserError("Invalid media byte range.");
  auto raw = smb2_open(impl->ctx, path.c_str(), O_RDONLY);
  if (!raw)
    throw UserError("The NAS file could not be opened.");
  auto close = [this](smb2fh *file) { smb2_close(impl->ctx, file); };
  std::unique_ptr<smb2fh, decltype(close)> file(raw, close);
  Bytes result(std::min<uint64_t>(length, value.smb2_size - offset));
  if (result.empty())
    return result;
  auto count = smb2_pread(impl->ctx, file.get(), result.data(),
                          uint32_t(result.size()), offset);
  if (count < 0)
    throw UserError("The NAS stopped responding while reading this file.");
  result.resize(size_t(count));
  return result;
}
} // namespace mediavault
