# frozen_string_literal: true
class Integrations::GithubController < Integrations::BaseController
  HMAC_DIGEST = OpenSSL::Digest.new('sha1')
  WEBHOOK_HANDLERS = {
    'push' => Changeset::CodePush,
    'pull_request' => Changeset::PullRequest,
    'issue_comment' => Changeset::IssueComment
  }.freeze

  def self.secret_token
    ENV['GITHUB_HOOK_SECRET']
  end

  protected

  def payload
    if payload = params[:payload]
      JSON.parse(payload)
    else
      params
    end
  end

  def validate_request
    unless valid_signature?
      record_log :warn, "Github webhook: failed to validate signature '#{signature}'"
      head(:unauthorized, message: 'Invalid signature')
    end
  end

  def deploy?
    webhook_handler&.valid_webhook?(payload)
  end

  # https://developer.github.com/webhooks/securing/
  def valid_signature?
    return true unless self.class.secret_token
    hmac = OpenSSL::HMAC.hexdigest(
      HMAC_DIGEST,
      self.class.secret_token,
      request.body.tap(&:rewind).read
    )

    Rack::Utils.secure_compare(signature, "sha1=#{hmac}")
  end

  def commit
    webhook_event.sha
  end

  def branch
    webhook_event.branch
  end

  private

  def service_type
    webhook_event.service_type
  end

  def webhook_event
    @webhook_event ||= webhook_handler.changeset_from_webhook(project, payload)
  end

  def webhook_handler
    WEBHOOK_HANDLERS[request.headers['X-Github-Event']]
  end

  def signature
    request.headers['X-Hub-Signature'].to_s
  end
end
