require "http"

module PlexMediaServerExporter
  module Middleware
    class Collector
      def initialize(app)
        @app = app
        @registry = ::Prometheus::Client.registry

        # Plex configs
        @plex_addr = ENV["PLEX_ADDR"] || "http://localhost:32400"
        @plex_token = ENV["PLEX_TOKEN"]
        @plex_timeout = ENV["PLEX_TIMEOUT"]&.to_i || 10
        @plex_retries_count = ENV["PLEX_RETRIES_COUNT"]&.to_i || 0

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
          labels: [:state, :user_id, :username],
        )
        @metrics[:audio_transcode_sessions_count] = @registry.gauge(
          :"#{@metrics_prefix}_audio_transcode_sessions_count",
          docstring: "Number of current sessions that are transcoding audio",
          labels: [:state, :user_id, :username],
        )
        @metrics[:video_transcode_sessions_count] = @registry.gauge(
          :"#{@metrics_prefix}_video_transcode_sessions_count",
          docstring: "Number of current sessions that are transcoding video",
          labels: [:state, :user_id, :username],
        )
        @metrics[:media_downloads_count] = @registry.gauge(
          :"#{@metrics_prefix}_media_downloads_count",
          docstring: "Number of current media downloads",
          labels: [:user_id, :username],
        )
      end

      def call(env)
        case env["PATH_INFO"]
        when "/metrics"
          collect_metrics
        end

        @app.call(env)
      end

      def collect_metrics
        log(step: "collect_metrics")

        begin
          capabilities_resource = send_plex_api_request(method: :get, endpoint: "/identity").dig("MediaContainer")
          metric_up_value = 1

          log(plex_up: true)

          set_gauge_metric_values_or_reset_missing(
            metric: @metrics[:info],
            values: {
              { version: capabilities_resource.dig("version") } => 1,
            },
          )
        rescue HTTP::Error
          log(plex_up: false)

          # Value of 0 means there's no heartbeat
          metric_up_value = 0
        ensure
          set_gauge_metric_values_or_reset_missing(
            metric: @metrics[:up],
            values: {
              {} => metric_up_value,
            },
          )
        end

        [
          -> { collect_session_metrics },
          -> { collect_activity_metrics },
          -> { collect_media_metrics },
        ].each do |collection|
          collection.call
        rescue HTTP::Error
          # Skip if it errors out
        end
      end

      private

      def log(**labels)
        puts(labels.to_a.map { |k, v| "#{k}=#{v}" }.join(" "))
      end

      def collect_activity_metrics
        values = Hash.new { |h, k| h[k] = 0 }

        send_plex_api_request(method: :get, endpoint: "/activities")
          .dig("MediaContainer", "Activity")
          &.each do |activity_resource|
            next unless activity_resource.dig("type") == "media.download"

            # The title will be something like "Media download by user123"
            username = activity_resource.dig("title").split(/\s+/).last

            labels = {
              user_id: activity_resource.dig("userID"),
              username: username,
            }

            values[labels] += 1
          end

        set_gauge_metric_values_or_reset_missing(metric: @metrics[:media_downloads_count], values: values)
      end

      def collect_session_metrics
        collected = {}
        users_by_id = {}

        # Initialize
        [:all, :audio_transcode, :video_transcode].each do |kind|
          collected[kind] = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = 0 } }
        end

        send_plex_api_request(method: :get, endpoint: "/status/sessions")
          .dig("MediaContainer", "Metadata")
          &.each do |session_resource|
            state = session_resource.dig("Player", "state")
            user_id = session_resource.dig("User", "id")
            users_by_id[user_id] ||= {
              username: session_resource.dig("User", "title"),
            }

            if (transcode_session = session_resource.dig("TranscodeSession"))
              if transcode_session.dig("audioDecision") == "transcode"
                collected[:audio_transcode][state][user_id] += 1
              end

              if transcode_session.dig("videoDecision") == "transcode"
                collected[:video_transcode][state][user_id] += 1
              end
            end

            collected[:all][state][user_id] += 1
          end

        collected.each do |metric_kind, counts_by_state_by_user_id|
          values = {}

          counts_by_state_by_user_id.each do |state, counts_by_user_id|
            counts_by_user_id.each do |user_id, count|
              username = users_by_id.dig(user_id, :username)

              values[{ state: state, user_id: user_id, username: username }] = count
            end
          end

          set_gauge_metric_values_or_reset_missing(metric: @metrics[:"#{metric_kind}_sessions_count"], values: values)
        end
      end

      def collect_media_metrics
        # Add ability to throttle this in case it negatively impacts
        if @media_metrics_collected_at
          if Time.now - @media_metrics_collected_at < @metrics_media_collecting_interval_seconds
            return false
          end
        end

        values = Hash.new { |h| h[k] = 0 }

        send_plex_api_request(method: :get, endpoint: "/library/sections")
          .dig("MediaContainer", "Directory")
          .each do |directory_resource|
            key = directory_resource.dig("key")
            media_title = directory_resource.dig("title")
            media_type = directory_resource.dig("type")
            media_count = fetch_media_section_count(key: key)

            values[{ title: media_title, type: media_type }] = media_count

            case media_type

            # If its for a show type library, also count its episodes
            when "show"
              show_episodes_count = fetch_media_section_count(key: key, params: { "type" => "4" })

              values[{ title: "#{media_title} - Episodes", type: "show_episode" }] = show_episodes_count
            end
          end

        set_gauge_metric_values_or_reset_missing(metric: @metrics[:media_count], values: values)

        @media_metrics_collected_at = Time.now
      end

      def fetch_media_section_count(key:, params: {}, **options)
        send_plex_api_request(
          method: :get,
          endpoint: "/library/sections/#{key}/all",
          params: params.merge(
            # Don't return any items, just the count, to keep the request speedy
            "X-Plex-Container-Size" => "0",
            "X-Plex-Container-Start" => "0",
          ),
          **options,
        )
          .dig("MediaContainer", "totalSize")
      end

      def send_plex_api_request(method:, endpoint:, **options)
        retries_count = 0

        # Keep trying request if it fails until number of retries have been exhausted
        loop do
          url = "#{@plex_addr}#{endpoint}"

          log(method: method, url: url)

          response = HTTP
            .timeout(@plex_timeout)
            .headers(
              "X-Plex-Token" => @plex_token,
              "Accept" => "application/json",
            )
            .public_send(method, url, **options)

          return JSON.parse(response)
        rescue HTTP::Error => e
          raise(e) if retries_count >= @plex_retries_count

          retries_count += 1
        end
      end

      # Set metric values and reset all other labels that werenn't passed in
      def set_gauge_metric_values_or_reset_missing(metric:, values:)
        missing_labels_collection = metric.values.keys - values.keys

        # Reset all values with labels that weren't passed in
        missing_labels_collection.each { |l| metric.set(0, labels: l) }

        values.each do |labels, labels_value|
          metric.set(labels_value, labels: labels)
        end
      end
    end
  end
end
