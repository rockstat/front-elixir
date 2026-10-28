# ===== Сборка release =====
FROM hexpm/elixir:1.20.4-erlang-29.1.2-debian-bookworm-20261020-slim AS build

ENV MIX_ENV=prod

WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

# зависимости отдельным слоем — кэшируются, пока не меняется mix.lock
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config/config.exs config/
COPY lib lib
COPY priv priv

RUN mix compile --warnings-as-errors && mix release

# ===== Рантайм =====
FROM debian:bookworm-20261020-slim

# BEAM динамически линкуется с openssl
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=8080

WORKDIR /app

COPY --from=build /build/_build/prod/rel/rockstat_front ./
# YAML-конфиг читается из рабочей директории (./config), в release не входит
COPY config/*.yml config/

RUN useradd --system --home /app rockstat && chown -R rockstat /app
USER rockstat

EXPOSE 8080

# healthcheck балансировщика — GET /health (curl в образ не ставим)
ENTRYPOINT ["/app/bin/rockstat_front"]
CMD ["start"]
