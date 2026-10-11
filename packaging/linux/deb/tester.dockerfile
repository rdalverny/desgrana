FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        libqt6widgets6 libqt6gui6 libqt6core6 \
        libcurl4 \
    && rm -rf /var/lib/apt/lists/*
