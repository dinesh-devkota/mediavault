#include "Core.h"
#include "KeyPolicy.h"
#include <algorithm>
#include <apmf/array.h>
#include <apmf/iface/com/amazon/kepler/crypto/ICrypto.h>
#include <apmf/iface/com/amazon/kepler/crypto/IDecryptionContext.h>
#include <apmf/iface/com/amazon/kepler/crypto/IEncryptionContext.h>
#include <apmf/iface/com/amazon/kepler/crypto/IGcmContextBuilder.h>
#include <apmf/iface/com/amazon/kepler/crypto/ISymmetricAlgorithm.h>
#include <apmf/iface/com/amazon/kepler/crypto/ISymmetricKey.h>
#include <apmf/iface/com/amazon/kepler/file_system/IDirEntry.h>
#include <apmf/iface/com/amazon/kepler/file_system/IFileSystem2.h>
#include <apmf/iface/com/amazon/kepler/file_system/IFileSystems.h>
#include <apmf/iface/com/amazon/kepler/file_system/Metadata.h>
#include <apmf/iface/com/amazon/kepler/keystore/BlockMode.h>
#include <apmf/iface/com/amazon/kepler/keystore/IKeystore.h>
#include <apmf/iface/com/amazon/kepler/keystore/IKeystoreKey.h>
#include <apmf/iface/com/amazon/kepler/keystore/IKeystoreModule.h>
#include <apmf/iface/com/amazon/kepler/keystore/IKeystoreSymmetricKeyBuilder.h>
#include <apmf/iface/com/amazon/kepler/security/IKeplerSecurityModule.h>
#include <apmf/process.h>
#include <apmf/ptr.h>
#include <stdexcept>

namespace mediavault {
namespace crypto = apmf::iface::com::amazon::kepler::crypto;
namespace keystore = apmf::iface::com::amazon::kepler::keystore;
namespace filesystem = apmf::iface::com::amazon::kepler::file_system;
namespace security = apmf::iface::com::amazon::kepler::security;
namespace {
std::string recordPrefix(const std::string &id) {
  const char *hex = "0123456789abcdef";
  std::string encoded;
  for (unsigned char c : safeID(id)) {
    encoded += hex[c >> 4];
    encoded += hex[c & 15];
  }
  // Encoding excludes the '-' delimiter, so a source named a-b cannot be
  // mistaken for an encrypted generation belonging to source a.
  return "mediavault-secret-" + encoded + "-";
}
} // namespace

struct Vault::Impl {
  apmf::Ptr<crypto::ICrypto> crypto;
  apmf::Ptr<keystore::IKeystore> store;
  apmf::Ptr<crypto::ISymmetricKey> key;
  apmf::Ptr<filesystem::IFileSystem> files;
  std::mutex mutex;
  Impl() {
    auto process = apmf::GetProcessObject();
    crypto = process->getComponent("/com.amazon.kepler.crypto")
                 .QueryInterface<crypto::ICrypto>();
    auto principal = process->getComponent("/com.amazon.kepler.security")
                         .QueryInterface<security::IKeplerSecurityModule>()
                         ->getCurrentContextCredential();
    store = process->getComponent("/com.amazon.kepler.keystore")
                .QueryInterface<keystore::IKeystoreModule>()
                ->getMostSecurePrivateKeystore(principal);
    files = process->getComponent("/com.amazon.kepler.file_system")
                .QueryInterface<filesystem::IFileSystems>()
                ->getDefault();
    const std::string name = "mediavault.credential-encryption.v1";
    for (const auto &candidate : store->getAllKeys()) {
      if (candidate->getName() == name) {
        key = candidate.QueryInterface<crypto::ISymmetricKey>();
        break;
      }
    }
  }
  void requireKey(bool allowCreation) {
    if (key)
      return;
    bool encryptedDataExists = false;
    for (const auto &entry : files->getEntries("/data")) {
      std::string name(entry->getName());
      if (name.compare(0, 18, "mediavault-secret-") == 0) {
        encryptedDataExists = true;
        break;
      }
    }
    requireVaultKey(false, encryptedDataExists, allowCreation, [this] {
      auto builder = store->makeSymmetricKeyBuilder();
      builder->name("mediavault.credential-encryption.v1");
      builder->algorithm(crypto->getSymmetricAlgorithmByName(
          crypto::ISymmetricAlgorithm::AES256));
      builder->addBlockMode(keystore::BlockMode::GCM);
      builder->bits(256);
      builder->exportable(false);
      builder->purposes({"ENCRYPT", "DECRYPT"});
      key = builder->buildGenerated();
    });
  }
  std::vector<std::string> paths(const std::string &id) {
    const auto prefix = recordPrefix(id);
    std::vector<std::string> result;
    for (const auto &entry : files->getEntries("/data")) {
      std::string name(entry->getName());
      if (name.compare(0, prefix.size(), prefix) == 0) {
        const auto metadata = entry->getMetadata(true);
        if (metadata.size < 0 || metadata.size > 256 * 1024 ||
            result.size() >= 20)
          throw UserError(
              "Protected source data is invalid. Reconnect this source.");
        result.push_back("/data/" + name);
      }
    }
    return result;
  }
  JSON decode(const std::string &id, const std::string &path) {
    requireKey(false);
    auto envelope =
        JSON::parse(std::string(files->readFileAsString(path, "UTF-8")));
    if (envelope.at("version") != 1)
      throw UserError("Unsupported protected data version.");
    auto iv = unbase64(envelope.at("iv")),
         ciphertext = unbase64(envelope.at("data"));
    if (iv.size() != 12 || ciphertext.size() < 16)
      throw UserError("Protected data is damaged.");
    auto context =
        crypto->makeGcmCipherContextBuilder(crypto->getSymmetricAlgorithmByName(
            crypto::ISymmetricAlgorithm::AES256));
    context->key(key);
    context->iv({iv.begin(), iv.end()});
    context->additionalData({id.begin(), id.end()});
    auto bytes = context->buildDecryptionContext()->decrypt(
        {ciphertext.begin(), ciphertext.end()});
    auto result = JSON::parse(bytes.begin(), bytes.end());
    std::fill(bytes.begin(), bytes.end(), 0);
    return result;
  }
};
Vault::Vault() : impl(std::make_unique<Impl>()) {}
Vault::~Vault() = default;
Bytes Vault::random(size_t length) {
  if (!length || length > 64)
    throw UserError("Invalid random data size.");
  auto bytes = impl->crypto->getRandom(int32_t(length));
  return {bytes.begin(), bytes.end()};
}
JSON Vault::read(const std::string &id) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  JSON result;
  uint64_t latest = 0;
  for (const auto &path : impl->paths(id)) {
    auto record = impl->decode(id, path);
    auto version = record.at("sequence").get<uint64_t>();
    if (version > latest) {
      latest = version;
      result = record.at("value");
    }
  }
  return result;
}
void Vault::write(const std::string &id, const JSON &value,
                  const std::function<void()> &assertCurrent) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  assertCurrent();
  impl->requireKey(true);
  auto previous = impl->paths(id);
  uint64_t sequence = 1;
  for (const auto &path : previous)
    sequence = std::max(
        sequence, impl->decode(id, path).at("sequence").get<uint64_t>() + 1);
  auto plain = JSON{{"sequence", sequence}, {"value", value}}.dump();
  if (plain.size() > 128 * 1024)
    throw UserError("Protected source data is too large.");
  auto iv = random(12);
  auto context = impl->crypto->makeGcmCipherContextBuilder(
      impl->crypto->getSymmetricAlgorithmByName(
          crypto::ISymmetricAlgorithm::AES256));
  context->key(impl->key);
  context->iv({iv.begin(), iv.end()});
  context->additionalData({id.begin(), id.end()});
  auto encrypted =
      context->buildEncryptionContext()->encrypt({plain.begin(), plain.end()});
  std::fill(plain.begin(), plain.end(), '\0');
  auto envelope = JSON{{"version", 1},
                       {"iv", base64(iv)},
                       {"data", base64({encrypted.begin(), encrypted.end()})}}
                      .dump();
  auto nonce = random(16);
  std::string suffix;
  const char *hex = "0123456789abcdef";
  for (auto byte : nonce) {
    suffix += hex[byte >> 4];
    suffix += hex[byte & 15];
  }
  const auto path = "/data/" + recordPrefix(id) + suffix;
  assertCurrent();
  try {
    auto written = impl->files->writeStringToFile(path, envelope, "UTF-8");
    if (written != int32_t(envelope.size()) ||
        impl->decode(id, path).at("value") != value)
      throw UserError("Your protected settings could not be saved.");
    assertCurrent();
  } catch (...) {
    // A failed/abandoned write must not poison subsequent reads of the
    // previously authenticated generation.
    try {
      impl->files->removeFile(path);
    } catch (...) {
    }
    throw;
  }
  // Write and verify the new authenticated generation before removing the old.
  for (const auto &old : previous)
    impl->files->removeFile(old);
}
void Vault::remove(const std::string &id) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  for (const auto &path : impl->paths(id))
    impl->files->removeFile(path);
}
} // namespace mediavault
