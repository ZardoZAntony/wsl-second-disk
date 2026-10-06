FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash e2fsprogs util-linux passwd coreutils gawk shellcheck shfmt sudo python3 \
    && rm -rf /var/lib/apt/lists/*
COPY . /src
ENV WSL_SECOND_DISK_TEST_CONTAINER=1
CMD ["bash", "/src/tests/integration.sh"]
