require "rubygems"
require "bundler/setup"

require "rack"
require "prometheus/middleware/exporter"
require_relative "lib/middleware/collector"

use Rack::Deflater
use PlexMediaServerExporter::Middleware::Collector
use Prometheus::Middleware::Exporter

app = lambda do |_|
  [
    200,
    { "Content-Type" => "text/plain" },
    ["plex-media-server-exporter"],
  ]
end

run(app)
