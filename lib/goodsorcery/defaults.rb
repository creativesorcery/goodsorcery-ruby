# frozen_string_literal: true

module GoodSorcery
  # Default lists. Configuration copies them, so apps can add with +=, remove
  # with -= or replace them entirely.
  module Defaults
    # Mirrors Rails' generated filter_parameters plus the server's scrub list.
    FILTER_PARAMS = [
      /passw/i, /secret/i, /token/i, /_key/i, /api-?key/i, /crypt/i, /salt/i, /certificate/i,
      /otp/i, /ssn/i, /cvv/i, /cvc/i, /authorization/i, /cookie/i, /csrf/i, /xsrf/i,
      /session[-_]?id/i, /credit[-_]?card/i, /card[-_]?number/i, /signature/i, /email/i
    ].freeze

    # Class names (subclasses match too) that are never reported.
    IGNORE_EXCEPTIONS = %w[
      AbstractController::ActionNotFound
      ActionController::BadRequest
      ActionController::InvalidAuthenticityToken
      ActionController::InvalidCrossOriginRequest
      ActionController::MethodNotAllowed
      ActionController::NotImplemented
      ActionController::ParameterMissing
      ActionController::RoutingError
      ActionController::UnknownFormat
      ActionController::UnknownHttpMethod
      ActionDispatch::Http::MimeNegotiation::InvalidType
      ActionDispatch::Http::Parameters::ParseError
      ActiveRecord::RecordNotFound
      CGI::Session::CookieStore::TamperedWithCookie
      Rack::QueryParser::InvalidParameterError
      Rack::QueryParser::ParameterTypeError
      Sinatra::NotFound
      SignalException
      SystemExit
    ].freeze

    DISABLED_ENVIRONMENTS = %w[development test].freeze
    ENDPOINT = "https://app.goodsorcery.com"
  end
end
