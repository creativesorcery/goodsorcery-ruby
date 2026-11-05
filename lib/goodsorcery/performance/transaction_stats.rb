# frozen_string_literal: true

module GoodSorcery
  module Performance
    # What one finished unit of work contributes to the metrics.
    Sample = Struct.new(:kind, :name, :labels, :duration_ms, :failed, :db_ms, :http_ms, :view_ms, :ruby_ms,
                        :queue_wait_ms) do
      def self.from(recorder)
        new(recorder.kind, recorder.name, Labels.for(recorder), recorder.duration_ms, recorder.failed?,
            recorder.db_ms, recorder.http_ms, recorder.view_ms, recorder.ruby_ms, recorder.queue_wait_ms)
      end
    end

    # The labels sent with a transaction: method and route for web requests,
    # adapter and queue for jobs, and the source file of either.
    module Labels
      LIMITS = { "method" => 16, "route" => 255, "adapter" => 32, "queue" => 128, "source" => 500 }.freeze

      def self.for(recorder)
        labels = if recorder.kind == :web
                   { "method" => recorder.http_method, "route" => recorder.route }
                 else
                   { "adapter" => recorder.adapter, "queue" => recorder.queue }
                 end
        labels["source"] = recorder.source
        labels.each_with_object({}) do |(key, value), limited|
          limited[key] = Text.limit(value, LIMITS.fetch(key)) unless value.nil?
        end
      end
    end

    # One transaction's numbers for one minute (DESIGN.md 8.4): count,
    # failed, the summed duration and, per histogram bucket that has
    # requests, [count, db_ms, http_ms, view_ms, ruby_ms]. Jobs add the
    # summed queue wait and its bucket counts.
    class TransactionStats
      DECIMALS = 3

      attr_reader :count, :failed, :duration_ms, :buckets, :queue_wait_ms, :queue_wait, :labels

      def initialize
        @count = @failed = 0
        @duration_ms = 0.0
        @buckets = {}
        @queue_wait_ms = nil
        @queue_wait = {}
        @labels = {}
      end

      # +keep_labels+ is false for the "(other)" row, which has none.
      def add(sample, keep_labels: true)
        @labels = sample.labels if keep_labels
        @count += 1
        @failed += 1 if sample.failed
        @duration_ms += sample.duration_ms
        add_bucket(sample)
        add_queue_wait(sample.queue_wait_ms) if sample.queue_wait_ms
      end

      def to_h(kind, name)
        hash = { "kind" => kind.to_s, "name" => name }.merge(@labels)
        hash.merge!("count" => @count, "failed" => @failed, "duration_ms" => @duration_ms.round(DECIMALS),
                    "buckets" => bucket_rows)
        return hash unless @queue_wait_ms

        hash.merge("queue_wait_ms" => @queue_wait_ms.round(DECIMALS), "queue_wait" => @queue_wait.sort)
      end

      private

      def add_bucket(sample)
        row = (@buckets[Histogram.index(sample.duration_ms)] ||= [0, 0.0, 0.0, 0.0, 0.0])
        row[0] += 1
        row[1] += sample.db_ms
        row[2] += sample.http_ms
        row[3] += sample.view_ms
        row[4] += sample.ruby_ms
      end

      def add_queue_wait(wait_ms)
        @queue_wait_ms = (@queue_wait_ms || 0.0) + wait_ms
        index = Histogram.index(wait_ms)
        @queue_wait[index] = @queue_wait.fetch(index, 0) + 1
      end

      def bucket_rows
        @buckets.sort.map do |index, (count, *layers)|
          [index, count, *layers.map { |ms| ms.round(DECIMALS) }]
        end
      end
    end
  end
end
