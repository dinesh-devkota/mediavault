#include "MediaVaultNative.h"
#include <condition_variable>
#include <deque>
#include <thread>

using namespace com::amazon::kepler::turbomodule;
using mediavault::Backend;
namespace {
class Executor {
  std::mutex mutex;
  std::condition_variable available;
  std::deque<std::function<void()>> pending;
  std::vector<std::thread> workers;
  bool stopped = false;

public:
  Executor() {
    for (unsigned i = 0; i < 4; ++i)
      workers.emplace_back([this] {
        while (true) {
          std::function<void()> work;
          {
            std::unique_lock<std::mutex> lock(mutex);
            available.wait(lock,
                           [this] { return stopped || !pending.empty(); });
            if (stopped && pending.empty())
              return;
            work = std::move(pending.front());
            pending.pop_front();
          }
          work();
        }
      });
  }
  ~Executor() {
    {
      std::lock_guard<std::mutex> lock(mutex);
      stopped = true;
    }
    available.notify_all();
    for (auto &worker : workers)
      worker.join();
  }
  void submit(std::function<void()> work) {
    std::lock_guard<std::mutex> lock(mutex);
    if (pending.size() >= 64)
      throw mediavault::UserError(
          "Too many source requests. Please try again shortly.");
    pending.push_back(std::move(work));
    available.notify_one();
  }
};
Promise perform(std::shared_ptr<Backend> backend,
                std::function<std::string(Backend &, uint64_t)> operation) {
  const auto epoch = backend->generation.load();
  return Promise([backend = std::move(backend),
                  operation = std::move(operation),
                  epoch](std::shared_ptr<Promise> promise) {
    try {
      static Executor executor;
      executor.submit([backend, operation, epoch, promise] {
        try {
          if (backend->generation.load() != epoch)
            throw mediavault::UserError(
                "The profile or source changed. Please try again.");
          promise->resolve(operation(*backend, epoch));
        } catch (const mediavault::UserError &error) {
          promise->reject(Error(error.what()));
        } catch (...) {
          promise->reject(Error("The protected source operation failed. Check "
                                "your connection and device settings."));
        }
      });
    } catch (...) {
      promise->reject(
          Error("Too many source requests. Please try again shortly."));
    }
  });
}
} // namespace
namespace MediaVaultNativeTurboModule {
MediaVaultNative::MediaVaultNative() : backend(std::make_shared<Backend>()) {}
MediaVaultNative::~MediaVaultNative() noexcept {
  try {
    backend->revoke();
  } catch (...) {
  }
}
Promise MediaVaultNative::configureSource(std::string json, std::string user,
                                          std::string password) {
  return perform(backend, [json = std::move(json), user = std::move(user),
                           password = std::move(password)](
                              Backend &b, uint64_t epoch) mutable {
    return b.configure(json, std::move(user), std::move(password), false,
                       epoch);
  });
}
Promise MediaVaultNative::authenticateJellyfin(std::string json,
                                               std::string user,
                                               std::string password) {
  return perform(backend, [json = std::move(json), user = std::move(user),
                           password = std::move(password)](
                              Backend &b, uint64_t epoch) mutable {
    return b.configure(json, std::move(user), std::move(password), true, epoch);
  });
}
Promise MediaVaultNative::removeSource(std::string id) {
  backend->generation.fetch_add(1);
  return perform(backend, [id = std::move(id)](Backend &b, uint64_t epoch) {
    b.removeSource(id, epoch);
    return "null";
  });
}
Promise MediaVaultNative::updateSource(std::string json) {
  backend->generation.fetch_add(1);
  return perform(backend, [json = std::move(json)](Backend &b, uint64_t epoch) {
    b.updateSource(json, epoch);
    return "null";
  });
}
Promise MediaVaultNative::listDirectory(std::string id, std::string path) {
  return perform(backend, [id = std::move(id),
                           path = std::move(path)](Backend &b, uint64_t epoch) {
    return b.list(id, path, epoch);
  });
}
Promise MediaVaultNative::stat(std::string id, std::string path) {
  return perform(backend, [id = std::move(id),
                           path = std::move(path)](Backend &b, uint64_t epoch) {
    return b.stat(id, path, epoch);
  });
}
Promise MediaVaultNative::readRange(std::string id, std::string path,
                                    std::string offset, double length) {
  return perform(backend, [id = std::move(id), path = std::move(path),
                           offset = std::move(offset),
                           length](Backend &b, uint64_t epoch) {
    return b.read(id, path, offset, length, epoch);
  });
}
Promise MediaVaultNative::request(std::string id, std::string json) {
  return perform(backend, [id = std::move(id),
                           json = std::move(json)](Backend &b, uint64_t epoch) {
    return b.request(id, json, epoch);
  });
}
Promise MediaVaultNative::acquirePlaybackTicket(std::string id,
                                                std::string path,
                                                std::string query) {
  return perform(backend,
                 [id = std::move(id), path = std::move(path),
                  query = std::move(query)](Backend &b, uint64_t epoch) {
                   return b.ticket(id, path, query, epoch);
                 });
}
Promise MediaVaultNative::acquireImageTicket(std::string id, std::string path,
                                             std::string query) {
  return perform(backend,
                 [id = std::move(id), path = std::move(path),
                  query = std::move(query)](Backend &b, uint64_t epoch) {
                   return b.imageTicket(id, path, query, epoch);
                 });
}
Promise MediaVaultNative::revokeAll() {
  backend->generation.fetch_add(1);
  return perform(backend, [](Backend &b, uint64_t) {
    b.revoke();
    return "null";
  });
}
Promise MediaVaultNative::revokeResource(std::string uri) {
  return perform(backend, [uri = std::move(uri)](Backend &b, uint64_t) {
    b.revokeResource(uri);
    return "null";
  });
}
Promise MediaVaultNative::hasProfilePIN(std::string id) {
  return perform(backend, [id = std::move(id)](Backend &b, uint64_t epoch) {
    return b.hasPIN(id, epoch) ? "true" : "false";
  });
}
Promise MediaVaultNative::setProfilePIN(std::string id, std::string pin) {
  return perform(backend, [id = std::move(id), pin = std::move(pin)](
                              Backend &b, uint64_t epoch) mutable {
    b.setPIN(id, std::move(pin), epoch);
    return "null";
  });
}
Promise MediaVaultNative::verifyProfilePIN(std::string id, std::string pin) {
  return perform(backend, [id = std::move(id), pin = std::move(pin)](
                              Backend &b, uint64_t epoch) mutable {
    return b.verifyPIN(id, std::move(pin), epoch) ? "true" : "false";
  });
}
Promise MediaVaultNative::removeProfilePIN(std::string id) {
  return perform(backend, [id = std::move(id)](Backend &b, uint64_t epoch) {
    b.removePIN(id, epoch);
    return "null";
  });
}
} // namespace MediaVaultNativeTurboModule
