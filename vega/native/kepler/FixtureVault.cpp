#if !defined(MEDIAVAULT_VVD_FIXTURE) || !MEDIAVAULT_VVD_FIXTURE
#error "The in-memory vault belongs only to the isolated VVD fixture target."
#endif
#if defined(NDEBUG) || !defined(__x86_64__)
#error                                                                         \
    "The VVD fixture vault must never be compiled for Release or device hardware."
#endif

#include "Core.h"
#include "FixturePolicy.h"
#include <cerrno>
#include <mbedtls/platform_util.h>
#include <optional>
#include <sys/random.h>

// The fixture-only linker map exports this audit marker. Shipping builds do
// not compile this translation unit or export the symbol/string.
extern "C" __attribute__((used, visibility("default"))) const char *
mediaVaultVVDFixtureOnly() {
  return "MEDIAVAULT_VVD_FIXTURE_ONLY_V1";
}

namespace mediavault {
namespace {
void clear(std::string &value) {
  if (!value.empty())
    mbedtls_platform_zeroize(value.data(), value.size());
  value.clear();
}
void validateRecord(const std::string &id, const JSON &value) {
  safeID(id);
  if (id.compare(0, 7, "source_") == 0 && id.size() > 7) {
    if (!value.is_null()) {
      const auto source = Source::parse(value);
      requireFixtureSource(source);
      if (id != "source_" + source.id)
        throw UserError("Invalid simulator source record.");
    }
  } else if (id.compare(0, 4, "pin_") != 0 || id.size() <= 4) {
    throw UserError("Only synthetic source and profile records are allowed.");
  }
}
} // namespace

struct Vault::Impl {
  std::mutex mutex;
  std::map<std::string, std::string> records;
  ~Impl() {
    for (auto &[id, value] : records)
      clear(value);
  }
};

Vault::Vault() : impl(std::make_unique<Impl>()) {}
Vault::~Vault() = default;

Bytes Vault::random(size_t length) {
  if (!length || length > 64)
    throw UserError("Invalid random data size.");
  Bytes result(length);
  size_t offset = 0;
  while (offset < length) {
    const auto received =
        ::getrandom(result.data() + offset, length - offset, 0);
    if (received < 0 && errno == EINTR)
      continue;
    if (received <= 0) {
      mbedtls_platform_zeroize(result.data(), result.size());
      throw UserError("The simulator could not obtain secure random bytes.");
    }
    offset += static_cast<size_t>(received);
  }
  return result;
}

JSON Vault::read(const std::string &id) {
  validateRecord(id, nullptr);
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto found = impl->records.find(id);
  return found == impl->records.end() ? JSON(nullptr)
                                      : JSON::parse(found->second);
}

void Vault::write(const std::string &id, const JSON &value,
                  const std::function<void()> &assertCurrent) {
  validateRecord(id, value);
  auto encoded = value.dump();
  if (encoded.size() > 128 * 1024)
    throw UserError("The simulator record is too large.");
  std::lock_guard<std::mutex> lock(impl->mutex);
  assertCurrent();
  auto existing = impl->records.find(id);
  if (existing == impl->records.end() && impl->records.size() >= 128)
    throw UserError("Too many simulator records.");
  size_t retained = encoded.size();
  for (const auto &[storedID, stored] : impl->records)
    if (storedID != id)
      retained += stored.size();
  if (retained > 4 * 1024 * 1024)
    throw UserError("Simulator storage limit reached.");
  std::optional<std::string> previous;
  if (existing != impl->records.end())
    previous = std::move(existing->second);
  impl->records[id] = std::move(encoded);
  try {
    assertCurrent();
  } catch (...) {
    clear(impl->records.at(id));
    impl->records.erase(id);
    if (previous)
      impl->records.emplace(id, std::move(*previous));
    throw;
  }
  if (previous)
    clear(*previous);
}

void Vault::remove(const std::string &id) {
  validateRecord(id, nullptr);
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto found = impl->records.find(id);
  if (found != impl->records.end()) {
    clear(found->second);
    impl->records.erase(found);
  }
}
} // namespace mediavault
