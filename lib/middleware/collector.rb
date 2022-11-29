require "http"

module PlexMediaServerExporter
  module Middleware
    class Collector
      SESSION_COUNT_METRIC_KINDS = [:all, :audio_transcode, :video_transcode].freeze
      SESSION_STATES = ["buffering", "paused", "playing"].freeze

      def initialize(app)
        @app = app
        @registry = ::Prometheus::Client.registry

        # Plex configs
        @plex_addr = ENV["PLEX_ADDR"] || "http://localhost:32400"
        @plex_timeout = ENV["PLEX_TIMEOUT"]&.to_i || 10

        # Metrics configs
        @metrics_prefix = ENV["METRICS_PREFIX"] || "plex"
        @metrics_media_collecting_interval_seconds = ENV["METRICS_MEDIA_COLLECTING_INTERVAL_SECONDS"]&.to_i || 300

        # Initialize metrics
        @metrics = {}
        @metrics[:up] = @registry.gauge(
          :"#{@metrics_prefix}_up",
          docstring: "Server heartbeat",
        )
        @metrics[:info] = @registry.gauge(
          :"#{@metrics_prefix}_info",
          docstring: "Server diagnostics",
          labels: [:version],
        )
        @metrics[:media_count] = @registry.gauge(
          :"#{@metrics_prefix}_media_count",
          docstring: "Number of media in library",
          labels: [:title, :type],
        )
        @metrics[:all_sessions_count] = @registry.gauge(
          :"#{@metrics_prefix}_sessions_count",
          docstring: "Number of current sessions",
          labels: [:state],
        )
        @metrics[:audio_transcode_sessions_count] = @registry.gauge(
          :"#{@metrics_prefix}_audio_transcode_sessions_count",
          docstring: "Number of current sessions that are transcoding audio",
          labels: [:state],
        )
        @metrics[:video_transcode_sessions_count] = @registry.gauge(
          :"#{@metrics_prefix}_video_transcode_sessions_count",
          docstring: "Number of current sessions that are transcoding video",
          labels: [:state],
        )
      end

      def call(env)
        begin
          capabilities_resource = send_plex_api_request(method: :get, endpoint: "/").dig("MediaContainer")

          @metrics[:up].set(1)
          @metrics[:info].set(1,
            labels: {
              version: capabilities_resource.dig("version"),
            },
          )

          collect_session_metrics
          collect_media_metrics
        rescue HTTP::Error
          # Value of 0 means there's no heartbeat
          @metrics[:up].set(0)
        end

        @app.call(env)
      end

      private

      def collect_session_metrics
        count_metrics = Hash.new { |h, k| h[k] = {} }

        # Initialize
        SESSION_COUNT_METRIC_KINDS.each do |metric_kind|
          SESSION_STATES.each do |state|
            count_metrics[metric_kind][state] = 0
          end
        end

        send_plex_api_request(method: :get, endpoint: "/status/sessions")
          .dig("MediaContainer", "Metadata")
          &.each do |session_resource|
            state = session_resource.dig("Player", "state")

            if (transcode_session = session_resource.dig("TranscodeSession"))
              if transcode_session.dig("audioDecision") == "transcode"
                count_metrics[:audio_transcode][state] += 1
              end

              if transcode_session.dig("videoDecision") == "transcode"
                count_metrics[:video_transcode][state] += 1
              end
            end

            count_metrics[:all][state] += 1
          end

        SESSION_COUNT_METRIC_KINDS.each do |metric_kind|
          count_metrics[metric_kind].each do |state, count|
            @metrics[:"#{metric_kind}_sessions_count"].set(count, labels: { state: state })
          end
        end
      end

      def collect_media_metrics
        # Add ability to throttle this in case it negatively impacts
        if @media_metrics_collected_at
          if Time.now - @media_metrics_collected_at < @metrics_media_collecting_interval_seconds
            return false
          end
        end

        send_plex_api_request(method: :get, endpoint: "/library/sections")
          .dig("MediaContainer", "Directory")
          .each do |directory_resource|
            media_count = send_plex_api_request(
              method: :get,
              endpoint: "/library/sections/#{directory_resource.dig('key')}/all",
              params: {
                # Don't return any items, just the count, to keep the request speedy
                "X-Plex-Container-Size" => "0",
                "X-Plex-Container-Start" => "0",
              },
            )
              .dig("MediaContainer", "totalSize")

            @metrics[:media_count].set(media_count,
              labels: {
                title: directory_resource.dig("title"),
                type: directory_resource.dig("type"),
              },
            )
          end

        @media_metrics_collected_at = Time.now
      end

      def send_plex_api_request(method:, endpoint:, **options)
        response = HTTP
          .timeout(@plex_timeout)
          .headers(
            "X-Plex-Token" => ENV["PLEX_TOKEN"],
            "Accept" => "application/json",
          )
          .public_send(method, "#{@plex_addr}#{endpoint}", **options)

        JSON.parse(response)
      end
    end
  end
end
