# Rockstat Front (Elixir)

Elixir/BEAM-порт сервиса `@rockstat/front` (TypeScript).
Лицензия: [Apache 2.0](LICENSE). Полностью совместим
по проводу с остальной платформой: JSON-RPC 2.0 поверх Redis pub/sub
(протокол rock-me-ts), формат `BandResponse` с `type__`, flake-идентификаторы,
cyrb53-подпись тела (`dig`), контракт HTTP-ответов (CORS/cookie/заголовки).

## Запуск

```sh
mix deps.get
PORT=8080 REDIS_DSN=redis://127.0.0.1:6379 mix run --no-halt
```

Переменные окружения те же, что у TS-версии: `HOST`, `PORT`, `REDIS_DSN`,
`WORKER_ID`, `DATACENTER_ID`, `DOMAIN`, `STATSD_HOST`, `LOG_LEVEL`,
`NODE_ENV=production` для prod-режима.

Prod-сборка (release, один артефакт без Erlang на хосте не требуется):

```sh
MIX_ENV=prod mix release
_build/prod/rel/rockstat_front/bin/rockstat_front start
```

## Что где лежит

| Модуль | Порт чего |
|---|---|
| `Http.Router` | `http/http_server.ts` — роутинг, body/dig/gzip, cookie, CORS, рендер ответа |
| `Dispatcher` | `Dispatcher.ts` — пайплайн transform → enrich → handle → listeners, регистрации удалённых сервисов (`__iamalive`/`status`, TTL 15с) |
| `Rpc` | rock-me-ts `RPCAgnostic` + `RPCAdapterRedis` — JSON-RPC по Redis pub/sub, multi-запросы к энричерам |
| `TreeBus` | `bus/tree.ts` — иерархический роутинг ключей (чистая структура, без процесса) |
| `Handlers` / `Enrichers` / `Transformers` | `handlers/*`, `enrichers/userdata.ts`, `transformers/*` (MP Android/iOS/iOS-native, PostHog, track_batch) |
| `Helpers` | `helpers/*` — path_parts, cyrb53 (бит-в-бит с JS, UTF-16), flatten_dict, uid, JWT-decode |
| `Config` | rock-me-ts `AppConfig` — `config/*.yml` через EEx (аналог EJS) |
| `Ids` | `TheIds` — flake (формат flake-idgen) и round-counter для RPC id |
| `StaticData` | `StaticData.ts` — web-sdk lib.js с rtConfig-прелюдией, index/favicon |
| `Metrics` | statsd UDP (counters + timings, префикс `krn`) |

## Отличия от TS-версии (намеренные)

- **Один процесс на все ядра.** Вместо N воркеров Node на портах
  10003–10061 достаточно 1–2 инстансов; upstream-пул nginx сокращается.
- `GET /` отдаёт index (в TS корень падал на проверке имени сервиса и
  возвращал 400 — route для index был мёртвым кодом).
- WebSocket-сервер не перенесён: в TS `AppServer` он закомментирован.
- `FingerPrintEnricher` (xxhash) не перенесён — отключён в конфиге TS-версии.
- Keep-alive поведением управляет Bandit; `read_timeout` выставлен 75с —
  больше дефолтных 60с upstream keep-alive у nginx (см. историю с 502).
- YAML парсится по спеке 1.2: булевы значения в конфиге — `true/false`
  (js-yaml принимал `yes/no`).

## Смоук-тест

Поднимите Redis, запустите сервис и эмулятор удалённого сервиса из
скрэтчпада разработки (подписывается на каналы `testsvc`/`enrich`/`broadcast`,
регистрируется через `__iamalive`, отвечает на `status`/`enrich`/`hello`) —
либо проверьте вручную:

```sh
curl localhost:8080/coffee                         # 418 + X-My-Name
curl localhost:8080/lib.js | head -c 120           # web-sdk + rtConfig
curl 'localhost:8080/track/pageview?uid=12345678901'
curl -X POST -H 'Content-Type: application/json' \
  -d '{"api_key":"k","sent_at":"2026-01-01T00:00:00Z","batch":[{"event":"e","timestamp":"2026-01-01T00:00:00Z"}]}' \
  localhost:8080/posthog/batch                     # транформер → broadcast
```

## Лицензия

Apache License 2.0 — см. [LICENSE](LICENSE).
Copyright 2026 Dmitry Rodin.
