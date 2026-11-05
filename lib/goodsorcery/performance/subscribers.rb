# frozen_string_literal: true

module GoodSorcery
  module Performance
    # ActiveSupport::Notifications subscriptions (DESIGN.md 8.3), made once.
    # Every callback returns at once unless a recorder is active on this
    # fiber, and never raises into the instrumented code: a failure stops
    # recording for that unit of work (Performance.with_recorder).
    module Subscribers
      IGNORED_SQL_NAMES = %w[SCHEMA CACHE].freeze
      RENDER_EVENTS = %w[
        render_template.action_view render_layout.action_view
        render_partial.action_view render_collection.action_view
      ].freeze
      # retry_on and discard_on handle the exception inside perform_now, so
      # these mark the attempt as failed.
      JOB_FAILURE_EVENTS = %w[enqueue_retry.active_job retry_stopped.active_job discard.active_job].freeze

      module_function

      def subscribe
        return false if @subscribed || !defined?(::ActiveSupport::Notifications)

        @subscribed = true
        subscribe_timed(::ActiveSupport::Notifications)
        JOB_FAILURE_EVENTS.each { |name| ::ActiveSupport::Notifications.subscribe(name) { |*| on_job_failure } }
        RENDER_EVENTS.each { |name| ::ActiveSupport::Notifications.subscribe(name, RenderListener) }
        true
      end

      # Monotonic subscribers get (name, start, finish, id, payload).
      def subscribe_timed(notifications)
        notifications.monotonic_subscribe("sql.active_record") do |_name, start, finish, _id, payload|
          on_sql(start, finish, payload)
        end
        notifications.monotonic_subscribe("process_action.action_controller") do |_name, _start, _finish, _id, payload|
          on_action(payload)
        end
        notifications.monotonic_subscribe("enqueue.active_job") do |_name, start, finish, _id, payload|
          on_enqueue(start, finish, payload)
        end
      end

      def subscribed?
        @subscribed ? true : false
      end

      def on_sql(start, finish, payload)
        Performance.with_recorder do |recorder|
          next if payload[:cached] || IGNORED_SQL_NAMES.include?(payload[:name])

          recorder.add_sql(start, finish, payload[:sql], payload[:name], payload[:row_count]) do
            CallSite.capture(Performance.paths)
          end
        end
      end

      def on_action(payload)
        Performance.with_recorder do |recorder|
          next unless recorder.kind == :web && recorder.name.nil?

          controller = payload[:controller]
          recorder.name = "#{controller}##{payload[:action]}"
          recorder.view_runtime = payload[:view_runtime]&.to_f
          recorder.route = RoutePattern.for(payload[:request])
          recorder.source = SourceLocation.for(controller)
        end
      end

      def on_enqueue(start, finish, payload)
        Performance.with_recorder do |recorder|
          job = payload[:job]
          recorder.add_enqueue(start, finish, job.class.name, job.queue_name) if job
        end
      end

      def on_job_failure
        Performance.with_recorder { |recorder| recorder.failed! if recorder.kind == :job }
      end
    end

    # Evented listener for the render events: the start and finish of each
    # render, so nested renders are counted once (Recorder#render_finished).
    module RenderListener
      module_function

      def start(_name, _id, _payload)
        Performance.with_recorder { |recorder| recorder.render_started(Performance.monotonic) }
      end

      def finish(_name, _id, payload)
        Performance.with_recorder { |recorder| recorder.render_finished(Performance.monotonic, payload[:identifier]) }
      end
    end

    # The matched route's pattern ("/products/:id"), without "(.:format)".
    # Needs Rails 7.1 or newer; nil otherwise.
    module RoutePattern
      FORMAT_SUFFIX = "(.:format)"

      def self.for(request)
        return nil unless request.respond_to?(:route_uri_pattern)

        request.route_uri_pattern&.delete_suffix(FORMAT_SUFFIX)
      end
    end

    # The app-relative file that defines a controller or job class, cached
    # per class name. Classes outside the app root have none.
    module SourceLocation
      MAX_ENTRIES = 2_000
      @cache = {}
      @lock = Mutex.new

      def self.for(class_name)
        return nil if class_name.nil?

        name = class_name.to_s
        cached = @cache.fetch(name, false)
        return cached unless cached == false

        locate(name).tap { |path| @lock.synchronize { @cache[name] = path if @cache.size < MAX_ENTRIES } }
      end

      def self.locate(name)
        file, = Object.const_source_location(name)
        return nil unless file

        relative = Performance.paths.relative(file)
        relative.start_with?("/") ? nil : relative
      rescue NameError, ArgumentError
        nil
      end

      def self.clear
        @lock.synchronize { @cache.clear }
      end
    end
  end
end
