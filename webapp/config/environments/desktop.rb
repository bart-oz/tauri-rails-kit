require "active_support/core_ext/integer/time"

# Desktop environment — used for both `npm run tauri dev` and the production bundle.
#
# DESKTOP_MODE=true is injected by the Rust process manager only in production bundles
# (see desktop/src/ruby.rs build_ruby_env). In dev builds the shell env is inherited,
# so DESKTOP_MODE is absent. Use it to gate behaviour that differs between the two.
DESKTOP_PRODUCTION = ENV.key?("DESKTOP_MODE")

Rails.application.configure do
  # Dev: reload changed files on each request so edits appear without restart.
  # Production bundle: eager load everything once at boot for fast responses.
  config.enable_reloading = !DESKTOP_PRODUCTION
  config.eager_load = DESKTOP_PRODUCTION

  # Show full error pages in the webview.
  config.consider_all_requests_local = true

  config.action_controller.perform_caching = DESKTOP_PRODUCTION

  # Propshaft defaults both flags to Rails.env.development? only, so custom
  # environments must set them explicitly.
  # Dev: add Propshaft::Server middleware and sweep the asset manifest on each
  # request so CSS/JS/view changes appear immediately without restarting.
  # Production bundle: assets are precompiled by the bundle script; serve
  # statically via ActionDispatch::Static from public/assets/.
  config.assets.server = !DESKTOP_PRODUCTION
  config.assets.sweep_cache = !DESKTOP_PRODUCTION
  config.public_file_server.enabled = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # hotwire-spark defaults enabled to Rails.env.development? only.
  # In the desktop environment it's loaded via group :development, :desktop
  # (so Bundler includes it when RAILS_ENV=desktop). Set the flag directly
  # so the hotwire_spark.install initializer picks it up.
  # The defined? guard handles the production bundle where the group is excluded
  # via BUNDLE_WITHOUT=development:test:desktop.
  # hotwire-spark and web-console default to Rails.env.development? only.
  # Set via config so the hotwire_spark.config initializer propagates the value
  # to Hotwire::Spark.enabled before hotwire_spark.install checks enabled?.
  # The respond_to? guard handles the production bundle where both gems are
  # excluded via BUNDLE_WITHOUT=development:test:desktop.
  if config.respond_to?(:hotwire)
    config.hotwire.spark.enabled = !DESKTOP_PRODUCTION
  end
  if config.respond_to?(:web_console)
    config.web_console.development_only = false
  end

  # Desktop apps have no shared session infrastructure, so a per-boot generated
  # key is acceptable. The Rust process manager can inject SECRET_KEY_BASE via
  # the environment to make the key stable across restarts (preserving cookies).
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") { SecureRandom.hex(64) }

  # No SSL — app serves to localhost only.

  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store

  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.default_url_options = { host: "localhost" }

  config.i18n.fallbacks = true
  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]
end
