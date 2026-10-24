FROM rust:1.98-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM caddy:2 AS caddy

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates python3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/target/release/pocketdesk-relay /usr/local/bin/pocketdesk-relay
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy
COPY deploy/Caddyfile /etc/caddy/Caddyfile
COPY deploy/serve.py /usr/local/bin/serve.py
ENV XDG_DATA_HOME=/data XDG_CONFIG_HOME=/data/config
EXPOSE 4433/udp 8080/tcp
ENTRYPOINT ["python3", "/usr/local/bin/serve.py"]
