#pragma once
#include "Core.h"
#include <thread>

namespace mediavault {
class Relay {
public:
  struct Resource {
    std::function<void()> check;
    std::function<uint64_t()> size;
    std::function<Bytes(uint64_t, size_t)> read;
    std::string mime;
  };
  Relay();
  ~Relay();
  std::string add(const std::string &token, Resource resource);
  void revoke(const std::string &uri);
  void revokeAll();

private:
  struct State;
  std::shared_ptr<State> state;
  std::thread listener;
};
} // namespace mediavault
