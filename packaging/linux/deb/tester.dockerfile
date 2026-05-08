# Base image for make test-debian — rebuild with: make test-image
# Contains system deps (python3, Qt6) so test-debian needs no network access.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        libqt6widgets6 libqt6gui6 libqt6core6 \
    && rm -rf /var/lib/apt/lists/*
