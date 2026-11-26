# Headless Ubuntu build host following Amazon's Vega CI documentation.
FROM node:22-bookworm-slim@sha256:be979e5523c76fa4d5ca4ebd3099078f220aa47ec39c48ad5b5df9314debd6eb AS node
FROM ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl tar jq git build-essential cmake ninja-build pkg-config \
    python3 python3-dev unzip xz-utils lz4 libssl-dev && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/ /usr/local/
ARG VEGA_SDK_VERSION=2.0.15159
ARG VEGA_INSTALLER_SHA256=817e9d4d6fcee9a48abd9cb292eb5844299b41f8759134b8e64dea69a929186c
ENV NONINTERACTIVE=true SKIP_VVD_INSTALL=true VEGA_SDK_VERSION=${VEGA_SDK_VERSION}
RUN curl --fail --silent --show-error --location https://sdk-installer.vega.labcollab.net/get_vvm.sh --output /tmp/get_vvm.sh \
    && echo "${VEGA_INSTALLER_SHA256}  /tmp/get_vvm.sh" | sha256sum --check \
    && bash /tmp/get_vvm.sh && rm /tmp/get_vvm.sh
ENV PATH="/root/vega/bin:${PATH}"
RUN vega --version && node --version && npm --version
RUN apt-get update && apt-get install -y --no-install-recommends python3-tomli && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
CMD ["bash"]
