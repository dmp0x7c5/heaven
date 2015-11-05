# A class to handle incoming webhooks
class Receiver
  @queue = :events

  attr_accessor :event, :guid, :data

  def initialize(event, guid, data)
    @guid  = guid
    @event = event
    @data  = data
  end

  def self.perform(event, guid, data)
    receiver = new(event, guid, data)

    if receiver.active_repository?
      receiver.run!
    else
      Rails.logger.info "Repository is not configured to deploy: #{receiver.full_name}"
    end
  end

  def full_name
    data["repository"] && data["repository"]["full_name"]
  end

  def active_repository?
    if data["repository"]
      name  = data["repository"]["name"]
      owner = data["repository"]["owner"]["login"]
      repository = Repository.find_or_create_by(:name => name, :owner => owner)
      repository.active?
    else
      false
    end
  end

  def run_deployment!
    return if LockReceiver.new(data).run!

    if Heaven::Jobs::Deployment.locked?(guid, data)
      Rails.logger.info "Deployment locked for: #{Heaven::Jobs::Deployment.identifier(guid, data)}"
      Resque.enqueue(Heaven::Jobs::LockedError, guid, data)
    else
      Resque.enqueue(Heaven::Jobs::Deployment, guid, data)
    end
  end

  def run!
    if event == "deployment"
      run_deployment!
    elsif event == "deployment_status"
      Resque.enqueue(Heaven::Jobs::DeploymentStatus, data)
    elsif event == "status"
      Resque.enqueue(Heaven::Jobs::Status, guid, data)
    elsif event == "pull_request"
      handle_pull_request
    else
      Rails.logger.info "Unhandled event type, #{event}."
    end
  end

  def handle_pull_request
    # return unless data["action"].include? %w{synchronize open reopen}
    # TODO: Check why data["action"] is overwritten by "create"
    return if data["pull_request"]["state"] != "open"
    deployment_payload_from_pull_request!
    run_deployment!
  end

  def deployment_payload_from_pull_request!
    data["deployment"] = {
      "payload" => {
        "config" => { "provider" => "capistrano_pull_request" },
        "name" => "pull_request_number_#{data["number"]}"
      },
      "environment" => "staging",
      "id" => data["pull_request"]["id"],
      "sha" => data["pull_request"]["head"]["sha"],
      "ref" => data["pull_request"]["head"]["ref"],
      # Additional params for LockReceiver:
      "creator" => { "login" => data["pull_request"]["user"]["login"] },
      "task" => "deploy_pull_request"
    }
  end
end
