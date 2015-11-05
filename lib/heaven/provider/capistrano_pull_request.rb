module Heaven
  # Top-level module for providers.
  module Provider
    # The capistrano provider with docker based pull request flow modifications.
    class CapistranoPullRequest < DefaultProvider
      include ApiClient

      def initialize(guid, data)
        super
        @name = "capistrano_pull_request"
      end

      def task
        "deploy"
      end

      def environment
        "dynamic_staging"
      end

      def cap_exec_env
        {
          "PULL_REQUEST_NUMBER" => data["number"].to_s,
          "REVISION" => full_sha
        }
      end

      def send_deploy_info_comment
        api.add_comment(
          data["repository"]["full_name"],
          data["number"],
          "Deployed to: #{staging_url} log: #{output.url}"
        )
      end

      def staging_url
        "http://#{data["repository"]["name"]}-#{data["number"]}.staging.devguru.co"
      end

      def run!
        Timeout.timeout(timeout) do
          output.create
          start_deployment_timeout!
          credentials.setup!
          execute
          send_deploy_info_comment
        end
      rescue POSIX::Spawn::TimeoutExceeded, Timeout::Error => e
        Rails.logger.info e.message
        Rails.logger.info e.backtrace
        output.stderr += "\n\nDEPLOYMENT TIMED OUT AFTER #{timeout} SECONDS"
      rescue StandardError => e
        Rails.logger.info e.message
        Rails.logger.info e.backtrace
      ensure
        update_output
      end

      def execute
        return execute_and_log(["/usr/bin/true"]) if Rails.env.test?

        unless File.exist?(checkout_directory)
          log "Cloning #{repository_url} into #{checkout_directory}"
          execute_and_log(["git", "clone", clone_url, checkout_directory])
        end

        Dir.chdir(checkout_directory) do
          log "Fetching the latest code"
          execute_and_log(%w{git fetch})
          execute_and_log(["git", "reset", "--hard", sha])

          Bundler.with_clean_env do
            bundler_string = ["bundle", "install"]
            log "Executing bundler: #{bundler_string.join(" ")}"
            execute_and_log(bundler_string)

            deploy_command = ["bundle", "exec", "cap", environment, task]
            log "Executing capistrano: #{deploy_command.join(" ")} with #{cap_exec_env}"
            execute_and_log(deploy_command, cap_exec_env)
          end
        end
      end
    end
  end
end
