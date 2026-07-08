import Config

if Mix.env() in [:dev, :test] do
  import_config "#{config_env()}.exs"
end
