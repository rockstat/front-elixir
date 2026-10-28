# Rockstat Front (Elixir)

Elixir/BEAM-порт сервиса `@rockstat/front` (TypeScript). Полностью совместим
по проводу с остальной платформой: JSON-RPC 2.0 поверх Redis pub/sub
(протокол rock-me-ts), формат `BandResponse` с `type__`, flake-идентификаторы,
cyrb53-подпись тела (`dig`), контракт HTTP-ответов (CORS/cookie/заголовки).

Лицензия: [Apache 2.0](LICENSE).

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

## HTTP API

Принимаются методы `GET`, `POST` и `OPTIONS` (CORS preflight); остальные
получают `400`. Все ответы несут общий набор заголовков:

| Заголовок | Значение |
|---|---|
| `Access-Control-Allow-Origin` | заголовок `Origin` запроса, иначе `scheme://host` из `Referer`, иначе `*` |
| `Access-Control-Allow-Credentials` | `true` |
| `Access-Control-Expose-Headers` | `Content-Length,Content-Type` |
| `X-Frame-Options` / `X-XSS-Protection` | `SAMEORIGIN` / `1` |
| `Pragma`, `Cache-Control`, `Expires`, `Last-Modified` | запрет кеширования |
| `Set-Cookie` | идентификационная кука (см. ниже) |
| `X-Response-Time` | время обработки, мс |

### Идентификация (uid)

`uid` ищется по приоритету: query → body → cookie; найденное значение должно
быть строкой из 10–22 цифр (flake), иначе генерируется новый. В каждом ответе
кука обновляется: `uid=<значение>; Max-Age≈3 года; Path=/; HttpOnly; Secure;
SameSite=None`, `Domain` — из `X-Forwarded-Host`, иначе по `identify` из
конфига (`cookieDomain: auto` → домен верхнего уровня с точкой). Имя куки
может быть переопределено для сервиса (`uid_param`, напр. `uidq` у `gifq`).

### Native-режим

Сегмент `band` в любом месте пути (`/band/redir/go?to=...`) не участвует в
роутинге, но переключает формат ответа: вместо исполнения (редирект, гифка)
клиент получает JSON вида `{"type__": "redirect", "statusCode": 302,
"location": "..."}` — полный `BandResponse` без заголовков.

### Служебные эндпоинты

| Маршрут | Ответ |
|---|---|
| `GET /` | заставка Rockstat (`text/html`) |
| `GET /favicon.ico` | иконка (`image/x-icon`) |
| `GET /lib.js` | web-sdk (`lib.js`, в dev — `lib-dev.js`) с приклеенной прелюдией: `configure` c `initialUid`, `urlMark` и опциями `client.common`, плюс `setTimeDelta` для поправки клиентских часов |
| `GET /coffee` | `418 I'm a teapot`, заголовок `X-My-Name: <имя сервиса>` |
| `OPTIONS <любой>` | CORS preflight: `Allow-Methods: POST,GET`, `Allow-Headers`, `Max-Age: 86400` |

### Основной маршрут: `/:service/:name[/:projectId][.ext]`

`GET` или `POST`. Событие получает ключ шины `in.gen.<service>.<name>` и
проходит пайплайн transform → enrich → handle → broadcast.

- **Сегменты пути.** `service` и `name` обязаны матчить
  `^[a-zA-Z0-9._-]{1,50}$`, иначе `400`. Оба могут также прийти параметрами
  `service`/`name` в query или теле (приоритет: query → body → URL).
  `projectId` — третий сегмент, либо параметр query/body (число, по умолчанию 0).
- **Расширение** у последнего сегмента отрезается и задаёт разбор тела/канал:
  `.json` → JSON, `.gif` → канал `pixel` (ответ гифкой при любом хендлере
  track/pixel), `.js`/`.html` — соответствующий content-type. Без расширения
  используется заголовок `Content-Type`.
- **Тело POST** (лимит 1 МБ, при `Content-Encoding: gzip` распаковывается):
  JSON-объект — как есть; JSON-массив — заворачивается в `{"data": [...]}`;
  всё прочее разбирается как `application/x-www-form-urlencoded`.
  `data` события = тело + query (query при конфликте побеждает).
- **Ответ** определяется хендлером ключа (см. ниже); если хендлера нет —
  событие всё равно принято (обогащено и разослано в broadcast), а клиент
  получает `{"key": ..., "id": ..., "uid": ...}`.

### Встроенные сервисы

| Маршрут | Хендлер | Детали |
|---|---|---|
| `/track/<event>` | TrackHandler | канал `http` → `{"id": "<flake>"}`; канал `pixel` (запрос `.gif`) → гифка 1×1 |
| `/pixel/<event>`, алиас `/gif/*` | PixelHandler | всегда прозрачная гифка 1×1 |
| `/redir/<name>?to=<url>`, алиасы `/away/*`, `/go/*` | RedirectHandler | `302` на `to`; без `to` → `400` |
| `/hello/ping`, `/hello/hello` | HelloHandler | `{"message": "pong"}` / `{"message": "hi"}`; прочее → `404` |
| `/static/<имя>.<ext>` | StaticHandler | файл из `public/` (имя строго `[a-zA-Z0-9_-]{1,50}\.[a-zA-Z0-9]{1,5}`, content-type по расширению); нет файла → `400` |
| `/userdata/update?uid=...` | энричер UserData | пишет поля `data` (кроме `uid`, `ttl`) в Redis-хэш `s:<uid>` с TTL (`ttl`, по умолчанию 30 дней); любое другое событие `track`/`userdata` с uid получает сохранённое обратно в `data.stored` |

### Алиасы с особыми параметрами (`services_params` конфига)

| Алиас | Направляется в | Особенности |
|---|---|---|
| `gifq` | `pixel` | uid берётся из параметра/куки `uidq`; кука `uid` прокидывается в `pancake` |
| `t4k` | `track` | обязательна подпись тела: `?dig=<cyrb53(raw body)>`, значение — неотрицательное целое (`url_check_websdk`), иначе `400`; для события `ping38` в `pancake` собираются все куки кроме `REMEMBERME`/`PHPSESSID`, а `jwt_bridge` и `user_token` декодируются как JWT (без проверки подписи) |

### Приём батчей (трансформеры)

Каждый батч превращается в конверт `in.gen.batch.batch` + отдельные события,
которые уходят в broadcast; клиенту возвращается обычный ответ track-хендлера.
Битый батч не даёт ошибки — конверт уходит с полем `err`.

| Маршрут (POST) | Формат тела | События |
|---|---|---|
| `/app-track/events`, `/mp_handler/events_betand`, `/mp_handler/events_mbc` | `{"data": "<base64(JSON-массив)>"}` (Mixpanel Android) | `in.gen.events_mp_android.events` |
| `/app-track-ios/track-ios`, `/app-track-ios/events`, `/mp_handler/track-ios` | то же (Mixpanel iOS; `id` записи переносится в `internal_id`) | `in.gen.events_mp_ios.events` |
| `/ios/track` | `{"data": [<события>]}` — без base64; записи без `event` пропускаются | `in.gen.events_mp_ios.events` |
| `/posthog/batch` | `{"api_key", "sent_at", "batch": [...]}`; `timestamp` события → `origin_timestamp` | `in.gen.events_ph.events` |

Свойства событий «сплющиваются» (`properties.$os` → `properties_s_os`),
каждое получает `src` (projectId), `batch_timestamp`/`batch_source_id`/
`batch_event_number` и исходные `source_service`/`source_name`. Время события —
`properties_time` (секунды автоматически переводятся в мс), иначе серверное.

### Удалённые сервисы

Любой сервис платформы, объявивший по RPC роль `handler` для метода `m`,
получает запросы `/<svc>/<m>` (или все `/<svc>/*` при методе `*`); его ответ
с `type__` отдаётся клиенту как есть (редирект, пиксель, данные), любой другой
результат заворачивается в JSON-данные. Таймаут (по умолчанию 200 мс) → `500`.

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
