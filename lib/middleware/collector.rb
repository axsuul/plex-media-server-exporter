require "http"

module PlexMediaServerExporter
  module Middleware
    class Collector
      def initialize(app)
        @app = app
        @registry = ::Prometheus::Client.registry
        @metrics_prefix = ENV["METRICS_PREFIX"] || "plex"
        @metrics_media_collecting_interval_seconds = ENV["METRICS_MEDIA_COLLECTING_INTERVAL_SECONDS"]&.to_i || 300

        # Initialize metrics
        @metrics = {}
        @metrics[:info] = @registry.gauge(
          :"#{@metrics_prefix}_info",
          docstring: "Basic server info",
          labels: [:platform, :state, :version],
        )
        @metrics[:media_count] = @registry.gauge(
          :"#{@metrics_prefix}_media_count",
          docstring: "Number of media in library",
          labels: [:title, :type],
        )
        @metrics[:sessions_count] = @registry.gauge(
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
        info_labels = {
          version: nil,
          platform: nil,
        }

        begin
          capabilities_resource = send_plex_api_request(method: :get, endpoint: "/").dig("MediaContainer")
          info_labels[:version] = capabilities_resource.dig("version")
          info_labels[:platform] = capabilities_resource.dig("platform")

          @metrics[:info].set(1,
            labels: info_labels.merge(state: "up"),
          )

          sessions_count_by_state = Hash.new { |h, k| h[k] = 0 }
          audio_transcode_sessions_count_by_state = Hash.new { |h, k| h[k] = 0 }
          video_transcode_sessions_count_by_state = Hash.new { |h, k| h[k] = 0 }

          send_plex_api_request(method: :get, endpoint: "/status/sessions")
            .dig("MediaContainer", "Metadata")
            .each do |session_resource|
              state = session_resource.dig("Player", "state")

              if (transcode_session = session_resource.dig("TranscodeSession"))
                if transcode_session.dig("audioDecision") == "transcode"
                  audio_transcode_sessions_count_by_state[state] += 1
                end

                if transcode_session.dig("videoDecision") == "transcode"
                  video_transcode_sessions_count_by_state[state] += 1
                end
              end

              sessions_count_by_state[state] += 1
            end

          sessions_count_by_state.each do |state, count|
            @metrics[:sessions_count].set(count, labels: { state: state })
          end
          audio_transcode_sessions_count_by_state.each do |state, count|
            @metrics[:audio_transcode_sessions_count].set(count, labels: { state: state })
          end
          video_transcode_sessions_count_by_state.each do |state, count|
            @metrics[:video_transcode_sessions_count].set(count, labels: { state: state })
          end

          collect_media_metrics

        # Could not reach Plex so it's down
        rescue HTTP::ConnectionError
          @metrics[:info].set(1,
            labels: info_labels.merge(state: "down"),
          )
        end

        @app.call(env)
      end

      private

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
