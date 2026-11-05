# frozen_string_literal: true

module GoodSorcery
  module Performance
    # What integrations and subscribers call while a unit of work runs:
    # timing a request or job, reaching the fiber's recorder, and linking a
    # reported error. Extended into GoodSorcery::Performance.
    module Measurement
      # Wraps a Rack request (the middleware calls this when active?).
      def measure_request(env)
        recorder = start(:web)
        return yield unless recorder

        recorder.env = env
        recorder.http_method = env["REQUEST_METHOD"]
        response = yield
        recorder.response_status = response.first.to_i if response.is_a?(Array)
        response
      rescue Exception => e # rubocop:disable Lint/RescueException
        recorder&.raised!(exception_status(e))
        raise
      ensure
        finish(recorder) if recorder
      end

      # Wraps a job execution; +timing+ is a JobTiming.
      def measure_job(timing)
        recorder = start(:job)
        return yield unless recorder

        label_job(recorder, timing)
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        recorder&.raised!
        raise
      ensure
        finish(recorder) if recorder
      end

      # Yields the active recorder of this fiber; a failure stops recording
      # this unit of work and is logged by class name.
      def with_recorder
        recorder = Thread.current[RECORDER_KEY]
        return nil if recorder.nil? || recorder.broken?

        yield recorder
      rescue StandardError => e
        recorder&.broken!
        log.warn_every(:apm_subscriber_error, 60,
                       "performance recording failed (#{e.class}); a unit of work is not measured")
        nil
      end

      def http_recorder
        return nil if Thread.current[SUPPRESS_KEY]

        recorder = Thread.current[RECORDER_KEY]
        recorder unless recorder.nil? || recorder.broken?
      end

      def record_http(recorder, started, host, request, response)
        status = response.respond_to?(:code) ? response.code.to_i : nil
        recorder.add_http([started, monotonic], request.method, host, request.path, status)
      rescue StandardError => e
        recorder.broken!
        log.warn_every(:apm_http_error, 60, "could not record an HTTP call (#{e.class})")
      end

      # Client#notify links the first reported error to the unit of work.
      def note_error(event_id)
        recorder = Thread.current[RECORDER_KEY]
        recorder.error_event_id ||= event_id if recorder && event_id
      end

      private

      # The status Rails' ShowExceptions answers an escaping exception with
      # (404 for ActiveRecord::RecordNotFound, 400 for ParameterMissing…);
      # nil outside Rails.
      def exception_status(error)
        return nil unless defined?(::ActionDispatch::ExceptionWrapper)

        template_error = defined?(::ActionView::Template::Error) && error.is_a?(::ActionView::Template::Error)
        error = error.cause || error if template_error
        ::ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name)
      rescue StandardError
        nil
      end

      def label_job(recorder, timing)
        timing.label(recorder)
      rescue StandardError => e
        recorder.broken!
        log.warn_every(:apm_job_label_error, 60, "could not read job details for performance data (#{e.class})")
      end
    end

    # The payloads the :test delivery keeps instead of sending them
    # (GoodSorcery.test_performance_payloads).
    module TestPayloads
      PAYLOADS_LOCK = Mutex.new
      PAYLOADS = [] # rubocop:disable Style/MutableConstant

      def store_test_payload(path, body)
        PAYLOADS_LOCK.synchronize { PAYLOADS << { "path" => path, "body" => body } }
      end

      def test_payloads
        PAYLOADS_LOCK.synchronize { PAYLOADS.dup }
      end

      def clear_test_payloads
        PAYLOADS_LOCK.synchronize { PAYLOADS.clear }
      end
    end
  end
end
