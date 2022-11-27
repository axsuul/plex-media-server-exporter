require "rubygems"
require "bundler/setup"

require "rack"
require "prometheus/middleware/exporter"
require_relative "lib/middleware/collector"

use Rack::Deflater
use PlexMediaServerExporter::Middleware::Collector
use Prometheus::Middleware::Exporter

app = -> {}

run app
