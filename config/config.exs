import Config

# В тестах HTTP-сервер не поднимается: роутер тестируется напрямую
# через Plug.Test, без привязки порта.
if config_env() == :test do
  config :rockstat_front, server: false
end
