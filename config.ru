require "rubygems"
require "bundler/setup"

require "rack"
require "prometheus/middleware/exporter"
require_relative "lib/middleware/collector"

use Rack::Deflater
use PlexMediaServerExporter::Middleware::Collector
use Prometheus::Middleware::Exporter

srand

app = lambda do |_|
  case rand
  when 0..0.8
    [200, { 'content-type' => 'text/html' }, ['OK']]
  when 0.8..0.95
    [404, { 'content-type' => 'text/html' }, ['Not Found']]
  else
    raise NoMethodError, 'It is a bug!'
  end
end

run app
