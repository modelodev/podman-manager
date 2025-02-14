require 'open3'
require 'logger'
require 'json'

class PodmanManager
  class PodmanError < StandardError; end

  def initialize(logger = Logger.new(STDOUT))
    @logger = logger
  end

  # Check if an image exists locally.
  def image_exists?(image_name)
    cmd = ["podman", "image", "exists", image_name]
    _, _, status = Open3.capture3(*cmd)
    status.success?
  end

  # Create a container from an image.
  # Yields each line of output if a block is provided.
  # Always returns the container ID.
  def create_container(image:, name: nil, **options)
    cmd = ["podman", "create"]
    cmd.push("--name", name) if name

    # Add additional options.
    options.each do |key, value|
      cmd.push("--#{key.to_s.gsub('_', '-')}", value.to_s)
    end

    cmd.push(image)
    
    stdout_str, stderr_str, status = Open3.capture3(*cmd)
    if block_given?
      stdout_str.each_line { |line| yield(line.chomp, :stdout) }
      stderr_str.each_line { |line| yield(line.chomp, :stderr) }
    end
    raise PodmanError, stderr_str unless status.success?
    stdout_str.strip
  end

  # Start a container.
  # Yields each line of output if a block is provided.
  def start_container(container_id)
    cmd = ["podman", "start", container_id]
    if block_given?
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield(line.chomp, :stdout) }
        stderr.each_line { |line| yield(line.chomp, :stderr) }
        raise PodmanError, "Error starting container" unless wait_thr.value.success?
      end
    else
      _, stderr, status = Open3.capture3(*cmd)
      raise PodmanError, stderr unless status.success?
      true
    end
  end

  # Stop a container.
  # Yields each line of output if a block is provided.
  def stop_container(container_id)
    cmd = ["podman", "stop", container_id]
    if block_given?
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield(line.chomp, :stdout) }
        stderr.each_line { |line| yield(line.chomp, :stderr) }
        raise PodmanError, "Error stopping container" unless wait_thr.value.success?
      end
    else
      _, stderr, status = Open3.capture3(*cmd)
      raise PodmanError, stderr unless status.success?
      true
    end
  end

  # Remove a container.
  # Yields each line of output if a block is provided.
  def remove_container(container_id, force: false)
    cmd = ["podman", "rm"]
    cmd.push("-f") if force
    cmd.push(container_id)
    if block_given?
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield(line.chomp, :stdout) }
        stderr.each_line { |line| yield(line.chomp, :stderr) }
        raise PodmanError, "Error removing container" unless wait_thr.value.success?
      end
    else
      _, stderr, status = Open3.capture3(*cmd)
      raise PodmanError, stderr unless status.success?
      true
    end
  end

  # Stream logs of a container in real time.
  # Requires a block to handle the output.
  def stream_container_logs(container_id, follow: true)
    raise ArgumentError, "A block is required for stream_container_logs" unless block_given?

    cmd = ["podman", "logs"]
    cmd.push("-f") if follow
    cmd.push(container_id)

    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      begin
        stdout_thread = Thread.new { stdout.each_line { |line| yield(line.chomp, :stdout) } }
        stderr_thread = Thread.new { stderr.each_line { |line| yield(line.chomp, :stderr) } }
        stdout_thread.join
        stderr_thread.join
      rescue IOError
        @logger.info "Stream closed"
      end
    end
  end

  # Check if a container exists.
  def container_exists?(container_id)
    cmd = ["podman", "container", "exists", container_id]
    _, _, status = Open3.capture3(*cmd)
    status.success?
  end

  # Get the status of a container.
  def container_status(container_id)
    return nil unless container_exists?(container_id)
    cmd = ["podman", "inspect", "--format", "{{.State.Status}}", container_id]
    stdout, _, status = Open3.capture3(*cmd)
    status.success? ? stdout.strip : nil
  end

  # Wait for a container to reach a specific status.
  # Raises an error if the desired status is not reached within the timeout.
  def wait_for_status(container_id, desired_status, timeout: 30, interval: 1)
    start_time = Time.now
    loop do
      current_status = container_status(container_id)
      return true if current_status == desired_status
      raise PodmanError, "Timeout waiting for container #{container_id} to reach status #{desired_status}" if Time.now - start_time > timeout
      sleep(interval)
    end
  end

  # Execute a block with a container, ensuring that the container is cleaned up afterwards.
  # Initializes the container environment and removes the container when done.
  def with_container(image:, name: nil, **options)
    container_id = create_container(image: image, name: name, **options)
    begin
      yield(container_id)
    ensure
      if container_exists?(container_id)
        # If running, attempt to stop before removal.
        current_status = container_status(container_id)
        if current_status == "running"
          begin
            stop_container(container_id)
          rescue PodmanError => e
            @logger.warn "Error stopping container #{container_id}: #{e.message}"
          end
        end
        remove_container(container_id, force: true)
      end
    end
  end

  # Get statistics for a specific container.
  # Returns a parsed JSON object with the container stats.
  def container_stats(container_id)
    cmd = ["podman", "stats", container_id, "--no-stream", "--format", "json"]
    stdout_str, stderr_str, status = Open3.capture3(*cmd)
    raise PodmanError, stderr_str unless status.success?
    result = JSON.parse(stdout_str)
    if result.is_a?(Array)
      if result.empty?
        raise PodmanError, "No stats available for container #{container_id}"
      else
        result = result.first
      end
    elsif !result.is_a?(Hash)
      raise PodmanError, "Unexpected podman stats output: #{result.inspect}"
    end

    # Transform keys: if Podman returned keys like "CPUPerc" and "MemUsage",
    # create our unified keys "cpu" and "mem_usage".
    if result.key?("CPUPerc")
      result["cpu"] = result.delete("CPUPerc")
    end
    if result.key?("MemUsage")
      result["mem_usage"] = result.delete("MemUsage")
    end
    # Ensure the keys exist even if missing.
    result["cpu"] ||= "0.00%"
    result["mem_usage"] ||= "0.00MiB / 0MiB"

    result
  end

  # Get the container IDs for containers created from a specific image.
  # Instead of relying solely on Podman's filter, list all containers and then
  # select those whose image field contains the given image name.
  def container_ids_by_image(image)
    cmd = ["podman", "ps", "-a", "--format", "{{.ID}} {{.Image}}"]
    stdout, stderr, status = Open3.capture3(*cmd)
    raise PodmanError, stderr unless status.success?
    lines = stdout.split("\n")
    ids = []
    lines.each do |line|
      id, img = line.split(" ", 2)
      ids << id if img.include?(image)
    end
    ids
  end

  # Get aggregated statistics for all containers of a specific image.
  # Returns a hash with individual container stats and aggregated stats.
  def aggregated_stats_for_image(image)
    ids = container_ids_by_image(image)
    stats = ids.map { |id| container_stats(id) }
    
    aggregated = stats.inject({ "cpu" => 0.0, "memory" => 0.0 }) do |acc, stat|
      # Process CPU value: remove any "%" and convert to float.
      cpu_value = stat["cpu"]
      cpu = cpu_value ? cpu_value.to_s.gsub("%", "").to_f : 0.0

      # Process memory usage; expect a format like "15.3MiB / 1GiB".
      mem_usage = stat["mem_usage"] || stat["memory"]
      memory = if mem_usage
                 mem_part = mem_usage.to_s.split("/").first.strip
                 mem_part.gsub(/[^\d\.]/, "").to_f
               else
                 0.0
               end

      acc["cpu"] += cpu
      acc["memory"] += memory
      acc
    end

    # Return a hash with string keys to match test expectations.
    { "containers" => stats, "aggregated" => aggregated }
  end
end

