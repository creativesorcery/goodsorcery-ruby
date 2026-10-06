# frozen_string_literal: true

module GoodSorcery
  module Delivery
    # Enqueues GoodSorcery::DeliveryJob with the filtered event as a JSON
    # string. Falls back to the background thread when ActiveJob is not loaded
    # or enqueueing raises. Note: the event is stored in the job backend.
    class ActiveJobQueue
      def initialize(serializer:, queue_name:, log:, &fallback_builder)
        @serializer = serializer
        @queue_name = queue_name
        @log = log
        @fallback_builder = fallback_builder
        @fallback = nil
        @lock = Mutex.new
      end

      def deliver(event)
        job = DeliveryJobLoader.job_class
        return deliver_in_background(event, "ActiveJob is not loaded") unless job

        json = @serializer.dump(event)
        return false unless json

        return true if enqueued?(job.set(queue: @queue_name).perform_later(json))

        deliver_in_background(event, "GoodSorcery::DeliveryJob was not enqueued")
      rescue StandardError => e
        deliver_in_background(event, "enqueueing GoodSorcery::DeliveryJob failed (#{e.class})")
      end

      def flush(timeout = 5)
        @fallback ? @fallback.flush(timeout) : true
      end

      def shutdown(timeout = 5)
        @fallback ? @fallback.shutdown(timeout) : true
      end

      private

      # perform_later returns false when a callback aborted the enqueue or
      # the adapter raised ActiveJob::EnqueueError.
      def enqueued?(job)
        return false unless job

        job.respond_to?(:successfully_enqueued?) ? job.successfully_enqueued? != false : true
      end

      def deliver_in_background(event, reason)
        @log.warn_every(:active_job_fallback, 60, "#{reason}; delivering in the background thread instead")
        fallback.deliver(event)
      end

      def fallback
        @fallback || @lock.synchronize { @fallback ||= @fallback_builder.call }
      end
    end

    # Defines GoodSorcery::DeliveryJob on first use, once ActiveJob is loaded.
    module DeliveryJobLoader
      def self.job_class
        return GoodSorcery::DeliveryJob if GoodSorcery.const_defined?(:DeliveryJob, false)
        return nil unless defined?(::ActiveJob::Base)

        require_relative "../delivery_job"
        GoodSorcery::DeliveryJob
      end
    end
  end
end
