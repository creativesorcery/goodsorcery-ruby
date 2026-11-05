# frozen_string_literal: true

module GoodSorcery
  module Performance
    # Labels a job recorder: name, adapter, queue, source and queue wait
    # (start − scheduled_at or enqueued_at, never negative). Subclasses read
    # them from an Active Job instance or a Sidekiq job hash.
    class JobTiming
      def label(recorder)
        recorder.name = name
        recorder.adapter = adapter
        recorder.queue = queue
        recorder.source = SourceLocation.for(source_class)
        recorder.queue_wait_ms = wait_ms(recorder.started_wall)
        recorder.job_details = self
      end

      private

      def wait_ms(started_wall)
        since = epoch_seconds(queued_since)
        since ? [(started_wall - since) * 1000.0, 0.0].max : nil
      end

      # A Time, epoch seconds (Float), epoch milliseconds (Sidekiq 8) or
      # an ISO 8601 string.
      def epoch_seconds(value)
        case value
        when Numeric then Event::Fields.epoch_seconds(value).to_f
        when String then Time.iso8601(value).to_f
        when nil then nil
        else value.to_time.to_f
        end
      rescue ArgumentError, NoMethodError
        nil
      end
    end

    # An Active Job execution (any adapter).
    class ActiveJobTiming < JobTiming
      def initialize(job)
        super()
        @job = job
      end

      def name = @job.class.name
      def queue = @job.queue_name&.to_s
      def source_class = @job.class.name
      def executions = @job.executions

      def adapter
        klass = @job.class
        name = klass.queue_adapter_name if klass.respond_to?(:queue_adapter_name)
        name&.to_s
      end

      private

      def queued_since
        scheduled = @job.respond_to?(:scheduled_at) ? @job.scheduled_at : nil
        scheduled || @job.enqueued_at
      end
    end

    # A Sidekiq job not wrapped by Active Job.
    class SidekiqTiming < JobTiming
      def initialize(job, queue, worker)
        super()
        @job = job
        @queue = queue || job["queue"]
        @worker = worker
      end

      def name = @job["class"].to_s
      def adapter = "sidekiq"
      def queue = @queue&.to_s
      def source_class = @worker&.class&.name || name

      # retry_count is absent on the first run and 0 on the first retry.
      def executions
        retries = @job["retry_count"]
        retries.is_a?(Integer) ? retries + 2 : 1
      end

      private

      def queued_since = @job["enqueued_at"]
    end
  end
end
