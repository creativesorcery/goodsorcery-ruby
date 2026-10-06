# frozen_string_literal: true

# Stands in for GoodSorcery::Transport in delivery tests. Results are
# scripted (a list of kinds); every batch it sees is recorded.
class FakeTransport
  Result = GoodSorcery::Transport::Result

  attr_reader :batches, :events

  def initialize(*script, gate: nil)
    @script = script
    @gate = gate
    @batches = []
    @events = []
    @mutex = Mutex.new
  end

  def post_batch(jsons)
    @gate&.pop
    result = @mutex.synchronize do
      @batches << jsons.map { |json| JSON.parse(json) }
      next_result
    end
    record_delivered(jsons) if result.success?
    result.retry_later? ? result.with_pending(jsons) : result
  end

  def post_event(json)
    post_batch([json])
  end

  def delivered_ids
    @mutex.synchronize { @events.map { |event| event["event_id"] } }
  end

  def attempts
    @mutex.synchronize { @batches.size }
  end

  private

  def record_delivered(jsons)
    @mutex.synchronize { @events.concat(jsons.map { |json| JSON.parse(json) }) }
  end

  def next_result
    step = @script.shift || :success
    return step if step.is_a?(Result)
    return Result.new(:rate_limited, status: 429, retry_after: 7) if step == :rate_limited
    return Result.new(:retryable, status: 503) if step == :retryable
    raise "transport exploded" if step == :raise

    Result.new(step, status: step == :success ? 202 : 422)
  end
end

# Records pauses instead of sleeping.
class RecordingSleeper
  attr_reader :pauses

  def initialize
    @pauses = []
  end

  def pause(seconds)
    @pauses << seconds
  end
end
