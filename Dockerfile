FROM rust:1.94-bookworm AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    libopenblas-dev \
    meson \
    ninja-build \
    python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY binpack-rust ./binpack-rust
COPY lc0 ./lc0
COPY fetch_and_rescore.sh ./fetch_and_rescore.sh

RUN cargo build --manifest-path binpack-rust/Cargo.toml --release --features ffi
RUN cp /app/binpack-rust/target/release/libsfbinpack.so /app/lc0/libsfbinpack.so
RUN /app/lc0/build.sh release \
    -Dlc0=false \
    -Drescorer=true \
    -Dgtest=false \
    -Dbuild_backends=true \
    -Dblas=true \
    -Dopenblas=true \
    -Donednn=false \
    -Dmkl=false \
    -Ddnnl=false \
    -Dopencl=false \
    -Dcudnn=false \
    -Dplain_cuda=false \
    -Dcutlass=false \
    -Dtensorflow=false \
    -Ddx=false \
    -Dsycl=off \
    -Dispc=false

FROM debian:bookworm-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libgomp1 \
    libopenblas0-pthread \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/fetch_and_rescore.sh ./fetch_and_rescore.sh
COPY --from=builder /app/lc0/build/release/rescorer ./lc0/build/release/rescorer
COPY --from=builder /app/lc0/libsfbinpack.so ./lc0/libsfbinpack.so

RUN chmod +x /app/fetch_and_rescore.sh /app/lc0/build/release/rescorer

ENTRYPOINT ["/app/fetch_and_rescore.sh"]
