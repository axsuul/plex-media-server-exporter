require "http"

module PlexMediaServerExporter
  module Middleware
    class Collector
      METRIC_PREFIX = "plex".freeze

      attr_reader :app, :registry

      def initialize(app)
        @app = app
        @registry = ::Prometheus::Client.registry

        puts ENV.inspect

        # Initialize metrics
        @metrics = {}
        @metrics[:info] = @registry.gauge(
          :"#{METRIC_PREFIX}_info",
          docstring: "Info",
          labels: [:platform, :state, :version],
        )
      end

      def call(env)
        app_response = @app.call(env)
        info_labels = {
          version: nil,
          platform: nil,
        }

        begin
          capabilities = send_plex_api_request(method: :get, endpoint: "/").dig("MediaContainer")
          info_labels[:version] = capabilities.dig("version")
          info_labels[:platform] = capabilities.dig("platform")

          @metrics[:info].set(1,
            labels: info_labels.merge(state: "up"),
          )
        rescue HTTP::ConnectionError
          @metrics[:info].set(1,
            labels: info_labels.merge(state: "down"),
          )
        end

        app_response
      end

      private

      def send_plex_api_request(method:, endpoint:, **options)
        addr = ENV["PLEX_ADDR"] || "http://localhost:32400"
        response = HTTP
          .headers(
            "X-Plex-Token" => ENV["PLEX_TOKEN"],
            "Accept" => "application/json",
          )
          .public_send(method, "#{addr}#{endpoint}", **options)

        JSON.parse(response)
      end
    end
  end
end
