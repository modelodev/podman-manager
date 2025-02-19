require 'pry'
require 'open3'
require 'logger'
require 'json'

module PodmanManager
  class PodmanError < StandardError; end
  class ContainerNotFoundError < PodmanError; end
  class TimeoutError < PodmanError; end
  class CommandError < PodmanError; end

  class PodmanCommand
    def initialize(base_command)
      @cmd = ["podman", base_command]
    end

    def add_flag(flag)
      @cmd.push(flag)
      self
    end

    def add_option(key, value)
      @cmd.push("--#{key.to_s.gsub('_', '-')}", value.to_s)
      self
    end

    def add_argument(arg)
      @cmd.push(arg)
      self
    end

    def build
      @cmd
    end
  end

  class ContainerStats
    def initialize(raw_stats)
      @stats = raw_stats
      normalize_stats
    end

    def cpu_percentage
      @stats["cpu"].to_s.gsub("%", "").to_f
    end

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

  class Container
    attr_reader :id

    def initialize(id, manager)
      @id = id
      @manager = manager
    end

    def start
      cmd = PodmanCommand.new("start").add_argument(@id).build
      execute_podman_command(cmd)
      begin
        wait_for_status(["running", "exited"], timeout: 2)
      rescue TimeoutError
        current = status
        raise unless current == "exited"
      end
    end

    def stop
      cmd = PodmanCommand.new("stop").add_argument(@id).build
      execute_podman_command(cmd)
      # En Podman, después de stop el estado es "exited"
      wait_for_status("exited", timeout: 5)
    end

    def remove(force: false)
      cmd = PodmanCommand.new("rm")
      cmd.add_flag("-f") if force
      cmd.add_argument(@id)
      execute_podman_command(cmd.build)
    end

    def exists?
      cmd = PodmanCommand.new("container").add_argument("exists").add_argument(@id).build
      _, _, status = Open3.capture3(*cmd)
      status.success?
    end

    def status
      cmd = PodmanCommand.new("inspect")
        .add_option("format", "{{.State.Status}}")
        .add_argument(@id)
        .build
      stdout, stderr, status = Open3.capture3(*cmd)
      if stderr.include?("no such container") || stderr.include?("no such object")
        raise ContainerNotFoundError, "Container #{@id} not found"
      end
      raise CommandError, stderr unless status.success?
      stdout.strip
    end

    def stats
      # Esperar primero a que el contenedor esté en running
      start_time = Time.now
      timeout = 10
      delay = 0.2

      while Time.now - start_time < timeout
        current_status = status
        if current_status == "running"
          begin
            return ContainerStats.new(@manager.container_stats(@id))
          rescue ContainerNotFoundError, CommandError
            # Si falla, continuar el bucle
          end
        elsif current_status == "exited"
          raise CommandError, "Container has exited, cannot get stats"
        end
        sleep(delay)
        delay = [delay * 1.5, 1.0].min
      end

      raise CommandError, "Container stats not available after #{timeout} seconds (status: #{status})"
    end

    def read_file(path)
      cmd = PodmanCommand.new("exec").add_argument(@id).add_argument("cat").add_argument(path).build
      stdout, stderr, status = Open3.capture3(*cmd)
      raise CommandError, stderr unless status.success?
      stdout
    end

    def file_exists?(path)
      cmd = PodmanCommand.new("exec").add_argument(@id).add_argument("test").add_argument("-f").add_argument(path).build
      _, _, status = Open3.capture3(*cmd)
      status.success?
    end

    private

    def wait_for_status(expected_status, timeout: 5)
      start_time = Time.now
      expected_states = Array(expected_status)
      loop do
        current_status = status
        return if expected_states.include?(current_status)

        if Time.now - start_time > timeout
          expected_msg = expected_states.size > 1 ? expected_states.join(' or ') : expected_states.first
          raise TimeoutError, "Container did not reach #{expected_msg} status within #{timeout} seconds (current: #{current_status})"
        end
        sleep(0.1)
      end
    end

    private

    def execute_podman_command(cmd)
      stdout, stderr, status = Open3.capture3(*cmd)
      return stdout if status.success?
      if stderr.include?("no such container") || stderr.include?("no such object")
        raise ContainerNotFoundError, "Container #{@id} not found"
      end
      raise CommandError, stderr unless stderr.empty?
      raise CommandError, "Command failed: #{cmd.join(' ')}"
    end
  end

  module_function

  def initialize(logger = Logger.new(STDOUT))
    @logger = logger
  end

  def image_exists?(image_name)
    cmd = PodmanCommand.new("image").add_argument("exists").add_argument(image_name).build
    _, _, status = Open3.capture3(*cmd)
    status.success?
  end

  def create_container(image:, name: nil, **options)
    cmd = PodmanCommand.new("create")
    cmd.add_option("name", name) if name

    options.each do |key, value|
      cmd.add_option(key, value)
    end

    cmd.add_argument(image)
    stdout_str, stderr_str, status = Open3.capture3(*cmd.build)

    if block_given?
      stdout_str.each_line { |line| yield(line.chomp, :stdout) }
      stderr_str.each_line { |line| yield(line.chomp, :stderr) }
    end

    raise CommandError, stderr_str unless status.success?
    Container.new(stdout_str.strip, self)
  end

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
            @logger.warn "Error stopping container #{container.id}: #{e.message}"
          end
        end
        container.remove(force: true)
      end
    end
  end

  def container_stats(container_id)
    cmd = PodmanCommand.new("stats")
            .add_argument(container_id)
            .add_flag("--no-stream")
            .add_option("format", "json")
            .build

    stdout_str, stderr_str, status = Open3.capture3(*cmd)

    # Only raise an error if the command failed
    unless status.success?
      if stderr_str.include?("no container with name or ID") || stderr_str.include?("no such container")
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
    rescue JSON::ParserError, RuntimeError => e
      raise CommandError, "Failed to parse stats output: #{e.message}. Output: #{stdout_str}"
    end
  end

  def execute_podman_command(cmd, error_message = nil)
    stdout, stderr, status = Open3.capture3(*cmd)
    return stdout if status.success?
    error_message ||= stderr.strip
    raise ContainerNotFoundError, "Container not found" if stderr.include?("no such container")
    raise CommandError, error_message unless error_message.empty?
    raise CommandError, "Command failed: #{cmd.join(' ')}"
  end

  def container_ids_by_image(image)
    # Extract the base name (e.g. "hola_loop:latest")
    image_base = image.split('/').last
    cmd = PodmanCommand.new("ps")
            .add_flag("-a")
            .add_option("format", "{{.ID}} {{.Image}}")
            .build

    stdout, stderr, status = Open3.capture3(*cmd)
    raise CommandError, stderr unless status.success?

    stdout.split("\n").select do |line|
      id, img = line.split(" ", 2)
      # Check if the reported image contains the base image name
      img && img.include?(image_base)
    end.map { |line| line.split(" ", 2).first }
  end

  def aggregated_stats_for_image(image)
    containers = container_ids_by_image(image).map { |id| Container.new(id, self) }
    return { "containers" => [], "aggregated" => { "cpu" => 0.0, "memory" => 0.0 } } if containers.empty?

    # Dar tiempo a los contenedores para iniciar y obtener stats
    start_time = Time.now
    timeout = 10
    running_containers = []
    stats = []

    while Time.now - start_time < timeout && running_containers.length < containers.length
      containers.each do |container|
        next if running_containers.include?(container)

        begin
          if container.status == "running"
            container_stats = container.stats
            stats << container_stats
            running_containers << container
          elsif container.status == "exited"
            # Si el contenedor ha terminado, no seguir intentándolo
            running_containers << container
          end
        rescue CommandError, ContainerNotFoundError
          # Ignorar errores y continuar con el siguiente contenedor
          next
        end
      end

      sleep(0.2) unless running_containers.length == containers.length
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

  def execute_podman_command(cmd, error_message = nil)
    if block_given?
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line { |line| yield(line.chomp, :stdout) }
        stderr.each_line { |line| yield(line.chomp, :stderr) }
        raise CommandError, error_message || "Command failed" unless wait_thr.value.success?
      end
    else
      _, stderr, status = Open3.capture3(*cmd)
      raise CommandError, stderr unless status.success?
      true
    end
  end
end
