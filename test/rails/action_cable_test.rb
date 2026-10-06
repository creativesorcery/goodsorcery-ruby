# frozen_string_literal: true

require_relative "support/rails_app"
require "action_cable/channel/test_case"
require "rack/mock_request"

class ChatError < StandardError; end
class HandledChatError < StandardError; end

class ChatChannel < ActionCable::Channel::Base
  rescue_from HandledChatError, with: :apologise

  def subscribed
    stream_from "chat_#{params[:room]}"
  end

  def speak(_data)
    raise ChatError, "cannot speak"
  end

  def shout(_data)
    raise HandledChatError, "too loud"
  end

  private

  def apologise(_error) = transmit("sorry")
end

class ChatChannelTest < ActionCable::Channel::TestCase
  tests ChatChannel

  def setup
    super
    GoodSorcery.configure { |config| config.delivery = :test }
    stub_connection
    env = Rack::MockRequest.env_for("http://example.org/cable", "HTTP_COOKIE" => "_session=abc",
                                                                "action_dispatch.request_id" => "cable-1",
                                                                "REMOTE_ADDR" => "198.51.100.4")
    connection.define_singleton_method(:env) { env }
    subscribe room: "lobby", access_token: "s3cr3t"
  end

  def events = GoodSorcery.test_events

  def test_an_action_error_is_reported_once_with_channel_params_and_data
    assert_raises(ChatError) { perform :speak, message: "hi", password: "pw" }
    event = events.first
    request = event["request"]

    assert_equal 1, events.size
    assert_equal "ChatChannel#speak", event["transaction"]
    assert_equal "http://example.org/cable", request["url"]
    assert_equal "cable-1", request["request_id"]
    assert_equal "198.51.100.4", request["remote_ip"]
    assert_equal "[FILTERED]", request["headers"]["Cookie"]
    assert_equal({ "room" => "lobby", "access_token" => "[FILTERED]" }, request["params"]["channel"].except("channel"))
    assert_equal({ "message" => "hi", "password" => "[FILTERED]", "action" => "speak" }, request["params"]["data"])
  end

  def test_errors_handled_by_rescue_from_are_not_reported
    perform :shout, message: "HI"

    assert_empty events
    assert_equal "sorry", transmissions.last
  end

  def test_scope_is_cleared_after_each_action
    assert_raises(ChatError) { perform :speak, message: "hi" }

    assert_nil Thread.current[GoodSorcery::Scope::STORAGE_KEY]
  end
end
