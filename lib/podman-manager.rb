require 'base64'
require 'open3'
require 'logger'
require 'json'

# PodmanManager - A Ruby wrapper for Podman container engine
#
# This module provides an interface to manage Podman containers, allowing you to:
# - Create, run, stop, and remove containers
# - Execute commands in containers
# - Read files from containers
# - Get container stats
# - Work with container images
#
# @example Basic usage
#   # Initialize with custom logger
#   PodmanManager.initialize(Logger.new(STDOUT))
#
#   # Create and run a container
#   container = PodmanManager.run_container(
#     image: "alpine:latest",
#     name: "my_container",
#     env: "MYVAR=value"
#   )
#
#   # Work with the container
#   puts container.status  # => "running"
#   stats = container.stats
#   puts "CPU: #{stats.cpu_percentage}%, Memory: #{stats.memory_usage}MB"
#
#   # Clean up
#   container.stop
#   container.remove
#
module PodmanManager
  # Custom error classes for better error handling
  class PodmanError < StandardError; end
  class ContainerNotFoundError < PodmanError; end
  class TimeoutError < PodmanError; end
  class CommandError < PodmanError; end

  # Configurable timeouts (in seconds)
  TIMEOUTS = {
    container_start: 2,    # Timeout when waiting for a container to start
    container_stop: 5,     # Timeout when waiting for a container to stop
    container_stats: 10,   # Timeout when collecting container stats
    aggregated_stats: 10   # Timeout when collecting stats for multiple containers
  }.freeze

  # Builder class for Podman commands
  #
  # @example
  #   cmd = PodmanCommand.new("run")
  #     .add_flag("-d")
  #     .add_option("name", "my_container")
  #     .add_argument("alpine:latest")
  #     .build
  #   # => ["podman", "run", "-d", "--name", "my_container", "alpine:latest"]
  #
  class PodmanCommand
    def initialize(base_command)
      @cmd = ["podman", base_command]
    end

    # Add a flag (option without value) to the command
    #
    # @param flag [String] The flag to add without the leading dash
    # @return [PodmanCommand] self for method chaining
    def add_flag(flag)
      @cmd.push(flag)
      self
    end

    # Add an option with value to the command
    #
    # @param key [String, Symbol] The option name (will be prefixed with "--")
    # @param value [String, Integer, Boolean] The value for the option
    # @return [PodmanCommand] self for method chaining
    def add_option(key, value)
      @cmd.push("--#{key.to_s.gsub('_', '-')}", value.to_s)
      self
    end

    # Add a positional argument to the command
    #
    # @param arg [String] The argument to add
    # @return [PodmanCommand] self for method chaining
    def add_argument(arg)
      @cmd.push(arg)
      self
    end

    # Build the final command array
    #
    # @return [Array<String>] The command as array of strings
    def build
      @cmd
    end
  end

  # Wrapper for executing commands
  class CommandRunner
    def initialize(logger = nil)
      @logger = logger
    end

    # Run a command and return its output and status
    #
    # @param cmd [Array<String>] The command to run
    # @return [Array<String, String, Process::Status>] stdout, stderr, and status
    def run(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      [stdout, stderr, status]
    end

    # Execute a command and handle common errors
    #
    # @param cmd [Array<String>] The command to run
    # @return [String] Standard output if successful
    # @raise [ContainerNotFoundError] If container doesn't exist
    # @raise [CommandError] If command fails for other reasons
    def execute(cmd)
      stdout, stderr, status = run(cmd)

      return stdout if status.success?

      if container_not_found?(stderr)
        raise ContainerNotFoundError, "Container not found"
      end

      raise CommandError, stderr unless stderr.empty?
      raise CommandError, "Command failed: #{cmd.join(' ')}"
    end

    # Execute a command and yield stdout/stderr lines as they come
    #
    # @param cmd [Array<String>] The command to run
    # @param error_message [String, nil] Custom error message
    # @yield [String, Symbol] Each line of output with :stdout or :stderr indicator
    # @raise [CommandError] If command fails
    #
    # @example Capturing and processing real-time output
    #   runner = PodmanManager::CommandRunner.new
    #   runner.execute_with_block(["podman", "build", "-t", "myimage", "."]) do |line, stream|
    #     case stream
    #     when :stdout
    #       if line.include?("Step")
    #         puts "Build progress: #{line}"
    #       end
    #     when :stderr
    #       puts "Error: #{line}"
    #     end
    #   end
    def execute_with_block(cmd, error_message = nil)
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield(line.chomp, :stdout) }
        stderr.each_line { |line| yield(line.chomp, :stderr) }
        raise CommandError, error_message || "Command failed" unless wait_thr.value.success?
      end
    end

    # Check if stderr indicates a container not found error
    #
    # @param stderr [String] The stderr output to check
    # @return [Boolean] True if error indicates container not found
    def container_not_found?(stderr)
      stderr.include?("no such container") || 
      stderr.include?("no such object") ||
      stderr.include?("no container with name or ID")
    end
  end

  # Container statistics representation
  class ContainerStats
    def initialize(raw_stats)
      @stats = raw_stats
      normalize_stats
    end

    # Get CPU usage percentage
    #
    # @return [Float] CPU usage percentage
    def cpu_percentage
      @stats["cpu"].to_s.gsub("%", "").to_f
    end

    # Get memory usage in MB
    #
    # @return [Float] Memory usage in MB
    def memory_usage
      mem_usage = @stats["mem_usage"] || @stats["memory"]
      if mem_usage
        mem_part = mem_usage.to_s.split("/").first.strip
        mem_part.gsub(/[^\d\.]/, "").to_f
      else
        0.0
      end
    end

    private

    # Normalize stats from different formats to a consistent structure
    def normalize_stats
      if @stats.key?("CPUPerc")
        @stats["cpu"] = @stats.delete("CPUPerc")
      end
      if @stats.key?("MemUsage")
        @stats["mem_usage"] = @stats.delete("MemUsage")
      end
      @stats["cpu"] ||= "0.00%"
      @stats["mem_usage"] ||= "0.00MiB / 0MiB"
    end
  end

  # Container representation
  class Container
    attr_reader :id

    # Initialize a container instance
    #
    # @param id [String] Container ID
    # @param manager [PodmanManager] Reference to the manager module
    # @param command_runner [CommandRunner, nil] Optional command runner
    def initialize(id, manager, command_runner = nil)
      @id = id
      @manager = manager
      @command_runner = command_runner || CommandRunner.new
    end

    # Start the container
    #
    # @return [void]
    # @raise [TimeoutError] If container doesn't start within timeout
    def start
      cmd = PodmanCommand.new("start").add_argument(@id).build
      @command_runner.execute(cmd)
      begin
        wait_for_status(["running", "exited"], timeout: TIMEOUTS[:container_start])
      rescue TimeoutError => e
        current = status
        # If the container exited quickly, that's acceptable
        # Otherwise re-raise the timeout error
        raise e unless current == "exited"
      end
    end

    # Stop the container
    #
    # @return [void]
    # @raise [TimeoutError] If container doesn't stop within timeout
    def stop
      cmd = PodmanCommand.new("stop").add_argument(@id).build
      @command_runner.execute(cmd)
      # In Podman, after stop the state is "exited"
      wait_for_status("exited", timeout: TIMEOUTS[:container_stop])
    end

    # Remove the container
    #
    # @param force [Boolean] Force removal even if running
    # @return [void]
    def remove(force: false)
      cmd = PodmanCommand.new("rm")
      cmd.add_flag("-f") if force
      cmd.add_argument(@id)
      @command_runner.execute(cmd.build)
    end

    # Check if the container exists
    #
    # @return [Boolean] True if container exists
    def exists?
      cmd = PodmanCommand.new("container").add_argument("exists").add_argument(@id).build
      _, _, status = @command_runner.run(cmd)
      status.success?
    end

    # Get container status
    #
    # @return [String] Container status (running, exited, etc.)
    # @raise [ContainerNotFoundError] If container doesn't exist
    def status
      cmd = PodmanCommand.new("inspect")
        .add_option("format", "{{.State.Status}}")
        .add_argument(@id)
        .build
      stdout, stderr, status = @command_runner.run(cmd)

      if @command_runner.container_not_found?(stderr)
        raise ContainerNotFoundError, "Container #{@id} not found"
      end

      raise CommandError, stderr unless status.success?
      stdout.strip
    end

    # Get container resource usage statistics
    #
    # @return [ContainerStats] Container statistics
    # @raise [CommandError] If container is not running
    # @raise [TimeoutError] If stats can't be collected within timeout
    def stats
      poll_with_timeout(
        timeout: TIMEOUTS[:container_stats],
        error_message: "Container stats not available"
      ) do
        current_status = status
        if current_status == "running"
          begin
            return ContainerStats.new(@manager.container_stats(@id))
          rescue ContainerNotFoundError, CommandError
            # If it fails, continue the loop
            nil
          end
        elsif current_status == "exited"
          raise CommandError, "Container has exited, cannot get stats"
        end
        nil
      end
    end

    # Read a file from the container
    #
    # @param path [String] Path to file inside container
    # @return [String] File contents
    # @raise [CommandError] If file doesn't exist or can't be read
    def read_file(path)
      cmd = PodmanCommand.new("exec").add_argument(@id).add_argument("cat").add_argument(path).build
      stdout, stderr, status = @command_runner.run(cmd)
      raise CommandError, stderr unless status.success?
      stdout
    end

    # Check if a file exists in the container
    #
    # @param path [String] Path to file inside container
    # @return [Boolean] True if file exists
    def file_exists?(path)
      cmd = PodmanCommand.new("exec").add_argument(@id).add_argument("test").add_argument("-f").add_argument(path).build
      _, _, status = @command_runner.run(cmd)
      status.success?
    end

    private

    # Wait until container reaches expected status
    #
    # @param expected_status [String, Array<String>] Status(es) to wait for
    # @param timeout [Integer] Maximum time to wait in seconds
    # @return [void]
    # @raise [TimeoutError] If expected status not reached within timeout
    def wait_for_status(expected_status, timeout: 5)
      poll_with_timeout(
        timeout: timeout,
        error_message: "Container did not reach expected status"
      ) do
        current_status = status
        expected_states = Array(expected_status)
        return true if expected_states.include?(current_status)
        nil
      end
    end

    # Generic polling method with timeout and exponential backoff
    #
    # @param timeout [Integer] Maximum time to wait in seconds
    # @param delay [Float] Initial delay between attempts
    # @param error_message [String, nil] Custom error message
    # @yield Block that returns non-nil when condition is met
    # @return [Object] Result from the block when condition is met
    # @raise [TimeoutError] If condition not met within timeout
    #
    # @example Waiting for a file to appear in a container
    #   result = container.send(:poll_with_timeout, timeout: 30, error_message: "File never appeared") do
    #     if container.file_exists?("/data/results.json")
    #       container.read_file("/data/results.json")
    #     else
    #       nil  # Return nil to continue polling
    #     end
    #   end
    #   puts "Got results: #{result}"
    #
    # @example Waiting for a specific container status
    #   container.send(:poll_with_timeout, timeout: 10) do
    #     status = container.status
    #     status == "running" ? true : nil
    #   end
    #   puts "Container is now running"
    def poll_with_timeout(timeout:, delay: 0.1, error_message: nil)
      start_time = Time.now
      backoff_delay = delay

      while Time.now - start_time < timeout
        result = yield
        return result if result

        sleep(backoff_delay)
        backoff_delay = [backoff_delay * 1.5, 1.0].min
      end

      current = begin
                  status
                rescue ContainerNotFoundError, CommandError => e
                  # If status check fails (e.g., container was removed), 
                  # just report "unknown" for the error message
                  "unknown (#{e.class.name}: #{e.message})"
                end

      msg = error_message || "Operation timed out"
      raise TimeoutError, "#{msg} after #{timeout} seconds (current status: #{current})"
    end
  end

  class << self
    attr_accessor :logger, :command_runner

    # Initialize the PodmanManager module
    #
    # @param logger [Logger] Custom logger instance
    # @return [void]
    def initialize(logger = Logger.new(STDOUT))
      @logger = logger
      @command_runner = CommandRunner.new(logger)
    end

    # Check if an image exists
    #
    # @param image_name [String] Image name or ID
    # @return [Boolean] True if image exists
    def image_exists?(image_name)
      cmd = PodmanCommand.new("image").add_argument("exists").add_argument(image_name).build
      _, _, status = command_runner.run(cmd)
      status.success?
    end

    # Run a new container
    #
    # @param image [String] Image name to run
    # @param name [String, nil] Optional container name
    # @param command [String, Array<String>, nil] Optional command to run
    # @param options [Hash] Additional options for podman run
    # @option options [String] :network Network settings (host, bridge, etc.)
    # @option options [String] :env Environment variables to set
    # @option options [String] :volume Volumes to mount
    # @option options [String] :cap_drop Capabilities to drop
    # @option options [String] :security_opt Security options
    # @option options [Boolean] :read_only Run container in read-only mode
    # @option options [String] :user Username or UID to run as
    # @option options [String] :workdir Working directory inside container
    # @yield [String, Symbol] If a block is given, it will be called with each line of output and a :stdout or :stderr indicator
    # @return [Container] The created container
    # @raise [CommandError] If container creation fails
    #
    # @example Basic usage
    #   container = PodmanManager.run_container(image: "alpine:latest", name: "my_container")
    #
    # @example With custom command
    #   container = PodmanManager.run_container(
    #     image: "alpine:latest",
    #     command: ["sh", "-c", "echo hello > /tmp/hello.txt && tail -f /dev/null"]
    #   )
    #
    # @example With security options
    #   container = PodmanManager.run_container(
    #     image: "nginx:latest",
    #     cap_drop: "ALL",
    #     security_opt: "no-new-privileges",
    #     read_only: "true"
    #   )
    #
    # @example Capturing output during container creation
    #   container = PodmanManager.run_container(image: "alpine:latest") do |line, stream|
    #     case stream
    #     when :stdout
    #       puts "STDOUT: #{line}"
    #     when :stderr
    #       puts "ERROR: #{line}"
    #     end
    #   end
    def run_container(image:, name: nil, command: nil, **options)
      cmd = PodmanCommand.new("run")
      cmd.add_flag("-d")  # Run in detached mode
      cmd.add_option("name", name) if name

      options.each do |key, value|
        cmd.add_option(key, value)
      end

      cmd.add_argument(image)

      # Add custom command if provided
      if command
        if command.is_a?(Array)
          command.each { |arg| cmd.add_argument(arg) }
        else
          cmd.add_argument(command)
        end
      end

      stdout_str, stderr_str, status = command_runner.run(cmd.build)

      if block_given?
        stdout_str.each_line { |line| yield(line.chomp, :stdout) }
        stderr_str.each_line { |line| yield(line.chomp, :stderr) }
      end

      raise CommandError, stderr_str unless status.success?
      Container.new(stdout_str.strip, self, command_runner)
    end

    # Stop a container by ID or name
    #
    # @param id_or_name [String] Container ID or name
    # @return [Boolean] True if successfully stopped
    # @raise [ContainerNotFoundError] If container doesn't exist
    # @raise [CommandError] If stop fails for other reasons
    def stop_container(id_or_name)
      cmd = PodmanCommand.new("stop").add_argument(id_or_name).build
      begin
        command_runner.execute(cmd)
        true
      rescue ContainerNotFoundError => e
        # Just propagate container not found errors
        raise e
      rescue CommandError => e
        if e.message.include?("is not running")
          # Container already stopped, consider this a success
          true
        else
          # Re-raise other command errors
          raise e
        end
      end
    end

    # Read a label from an image
    #
    # @param image [String] Image name or ID
    # @param label_key [String] Label key to read
    # @param decode [Boolean] Whether to Base64 decode the value
    # @return [String, nil] The label value or nil if not found
    # @raise [CommandError] If inspect fails
    def read_label(image, label_key, decode: false)
      cmd = PodmanCommand.new("inspect")
        .add_option("format", "{{ index .Config.Labels \"#{label_key}\" }}")
        .add_argument(image)
        .build

      stdout, stderr, status = command_runner.run(cmd)
      raise CommandError, "Failed to inspect image: #{stderr}" unless status.success?

      label_value = stdout.to_s.strip
      return nil if label_value.empty?
      decode ? Base64.decode64(label_value) : label_value
    end

    # Create a new container without starting it
    #
    # @param image [String] Image to use
    # @param name [String, nil] Optional container name
    # @param options [Hash] Additional options for podman create
    # @yield [String, Symbol] If a block is given, it will be called with each line of output and a :stdout or :stderr indicator
    # @return [Container] The created container
    # @raise [CommandError] If container creation fails
    #
    # @example Basic usage
    #   container = PodmanManager.create_container(image: "alpine:latest", name: "my_container")
    #
    # @example With block to capture output
    #   container = PodmanManager.create_container(image: "alpine:latest") do |line, stream|
    #     puts "#{stream}: #{line}" if stream == :stderr # Print only error output
    #   end
    def create_container(image:, name: nil, **options)
      cmd = PodmanCommand.new("create")
      cmd.add_option("name", name) if name

      options.each do |key, value|
        cmd.add_option(key, value)
      end

      cmd.add_argument(image)
      stdout_str, stderr_str, status = command_runner.run(cmd.build)

      if block_given?
        stdout_str.each_line { |line| yield(line.chomp, :stdout) }
        stderr_str.each_line { |line| yield(line.chomp, :stderr) }
      end

      raise CommandError, stderr_str unless status.success?
      Container.new(stdout_str.strip, self, command_runner)
    end

    # Create a container, yield to block, then remove the container
    #
    # @param image [String] Image to use
    # @param name [String, nil] Optional container name
    # @param options [Hash] Additional options for podman create
    # @yield [Container] The created container
    # @return [Object] Result of the block
    #
    # @example Basic usage
    #   result = PodmanManager.with_container(image: "alpine:latest") do |container|
    #     container.start
    #     # Work with the container
    #     container.read_file("/etc/hostname")
    #   end
    #   # Container is automatically stopped and removed after the block
    #
    # @example Processing files in a container
    #   content = PodmanManager.with_container(image: "my-data-processor:latest") do |container|
    #     container.start
    #     # Execute some processing
    #     container.read_file("/results/output.txt")
    #   end
    #   puts "Processing result: #{content}"
    def with_container(image:, name: nil, **options)
      container = create_container(image: image, name: name, **options)
      begin
        yield(container)
      ensure
        if container.exists?
          if container.status == "running"
            begin
              container.stop
            rescue PodmanError => e
              # If we can't stop the container cleanly, just log the error and continue
              # We'll try to force remove it anyway
              logger.warn "Error stopping container #{container.id}: #{e.message}" if logger
            end
          end
          container.remove(force: true)
        end
      end
    end

    # Get container stats
    #
    # @param container_id [String] Container ID
    # @return [Hash] Container stats data
    # @raise [ContainerNotFoundError] If container doesn't exist
    # @raise [CommandError] If stats can't be collected
    def container_stats(container_id)
      cmd = PodmanCommand.new("stats")
              .add_argument(container_id)
              .add_flag("--no-stream")
              .add_option("format", "json")
              .build

      stdout_str, stderr_str, status = command_runner.run(cmd)

      # Only raise an error if the command failed
      unless status.success?
        if command_runner.container_not_found?(stderr_str)
          raise ContainerNotFoundError, "Container #{container_id} not found"
        elsif stderr_str.include?("is not running")
          raise CommandError, "Container must be running to get stats"
        else
          raise CommandError, stderr_str
        end
      end

      begin
        result = JSON.parse(stdout_str)
        result = result.first if result.is_a?(Array)
        raise "Invalid stats format" unless result.is_a?(Hash)
        result
      rescue JSON::ParserError => e
        # Handle JSON parsing errors with detailed message
        raise CommandError, "Failed to parse stats JSON output: #{e.message}. Output: #{stdout_str}"
      rescue RuntimeError => e
        # Handle invalid format errors
        raise CommandError, "Invalid stats format: #{e.message}. Output: #{stdout_str}"
      end
    end

    # Find container IDs by image name
    #
    # @param image [String] Image name
    # @return [Array<String>] Array of container IDs
    # @raise [CommandError] If container list can't be obtained
    def container_ids_by_image(image)
      # Extract the base name (e.g. "hola_loop:latest")
      image_base = image.split('/').last
      cmd = PodmanCommand.new("ps")
              .add_flag("-a")
              .add_option("format", "{{.ID}} {{.Image}}")
              .build

      stdout, stderr, status = command_runner.run(cmd)
      raise CommandError, stderr unless status.success?

      stdout.split("\n").select do |line|
        id, img = line.split(" ", 2)
        # Check if the reported image contains the base image name
        img && img.include?(image_base)
      end.map { |line| line.split(" ", 2).first }
    end

    # Get aggregated stats for all containers of a specific image
    #
    # @param image [String] Image name
    # @return [Hash] Aggregated stats with container IDs
    def aggregated_stats_for_image(image)
      containers = container_ids_by_image(image).map { |id| Container.new(id, self, command_runner) }
      return { "containers" => [], "aggregated" => { "cpu" => 0.0, "memory" => 0.0 } } if containers.empty?

      running_containers = []
      stats = []

      # Use poll_with_timeout to collect container stats
      poll_container_stats(
        containers: containers,
        timeout: TIMEOUTS[:aggregated_stats]
      ) do |container, container_stats|
        stats << container_stats
        running_containers << container
      end

      {
        "containers" => running_containers.map(&:id),
        "aggregated" => {
          "cpu" => stats.sum(&:cpu_percentage).to_f,
          "memory" => stats.sum(&:memory_usage).to_f
        }
      }
    end

    private

    # Poll containers to collect their stats
    #
    # @param containers [Array<Container>] Containers to poll
    # @param timeout [Integer] Maximum time to wait
    # @yield [Container, ContainerStats] Each container and its stats
    # @return [Array<Container>] Containers that were polled successfully
    #
    # @example Collecting stats from multiple containers
    #   containers = container_ids.map { |id| Container.new(id, self) }
    #   all_stats = []
    #   
    #   poll_container_stats(containers: containers, timeout: 30) do |container, stats|
    #     all_stats << {
    #       id: container.id,
    #       cpu: stats.cpu_percentage,
    #       memory: stats.memory_usage
    #     }
    #   end
    #   
    #   all_stats.each do |stat|
    #     puts "Container #{stat[:id]}: CPU #{stat[:cpu]}%, Memory #{stat[:memory]}MB"
    #   end
    def poll_container_stats(containers:, timeout:)
      start_time = Time.now
      running_containers = []

      while Time.now - start_time < timeout && running_containers.length < containers.length
        containers.each do |container|
          next if running_containers.include?(container)

          begin
            if container.status == "running"
              container_stats = container.stats
              yield(container, container_stats)
              running_containers << container
            elsif container.status == "exited"
              # If container has exited, don't keep trying
              running_containers << container
            end
          rescue CommandError, ContainerNotFoundError => e
            # Ignore errors and continue with next container
            # Common errors: container stopped, was removed, or isn't accessible
            next
          end
        end

        sleep(0.2) unless running_containers.length == containers.length
      end

      running_containers
    end
  end

  # Default initialization
  initialize
end
