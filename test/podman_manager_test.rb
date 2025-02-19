require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'logger'
require_relative '../lib/podman-manager'

# Test suite for PodmanManager
class TestPodmanManager < Minitest::Test
  TEST_IMAGES = {
    exit:    'test/hola_exit:latest',
    loop:    'test/hola_loop:latest',
    file:    'test/file_test:latest',
    special: 'test/special_chars:latest',
    large:   'test/large_file:latest'
  }.freeze

  def setup
    @temp_dirs = {}
    @special_content = "Hello\nWorld\n测试\n€\n"
    @large_content   = "x" * 1_000_000
    build_all_images
  end

  def teardown
    @temp_dirs.each_value { |dir| FileUtils.remove_entry(dir) if Dir.exist?(dir) }
    TEST_IMAGES.values.each { |tag| remove_test_image(tag) }
  end

  # --- Helper methods for building and removing images ---

  # Creates a temporary directory, writes files, and builds an image.
  # files: a hash mapping relative file paths to their content.
  # dockerfile: the content of the Dockerfile.
  # image_tag: the tag for the built image.
  def build_temp_image(prefix, image_tag, dockerfile, files = {})
    dir = Dir.mktmpdir(prefix)
    @temp_dirs[prefix.to_sym] = dir
    files.each do |file, content|
      File.write(File.join(dir, file), content)
    end
    File.write(File.join(dir, "Dockerfile"), dockerfile)
    build_image(dir, image_tag)
  end

  def build_image(context_dir, image_tag)
    cmd = ["podman", "build", "-t", image_tag, context_dir]
    stdout, stderr, status = Open3.capture3(*cmd)
    raise "Failed to build image #{image_tag}: #{stderr}" unless status.success?
  end

  def remove_test_image(image_tag)
    cmd = ["podman", "rmi", "-f", image_tag]
    Open3.capture3(*cmd)
  end

  def build_all_images
    build_exit_image
    build_loop_image
    build_file_test_image
    build_special_chars_image
    build_large_file_image
  end

  def build_exit_image
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      CMD echo "hola"
    DOCKERFILE
    build_temp_image("hola_exit", TEST_IMAGES[:exit], dockerfile)
  end

  def build_loop_image
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      CMD sh -c 'while true; do echo "hola"; sleep 5; done'
    DOCKERFILE
    build_temp_image("hola_loop", TEST_IMAGES[:loop], dockerfile)
  end

  def build_file_test_image
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      COPY test.txt /etc/test.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_temp_image("file_test", TEST_IMAGES[:file], dockerfile, { "test.txt" => "hello world" })
  end

  def build_special_chars_image
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      COPY special.txt /etc/special.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_temp_image("special_chars_test", TEST_IMAGES[:special], dockerfile, { "special.txt" => @special_content })
  end

  def build_large_file_image
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      COPY large.txt /etc/large.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_temp_image("large_file_test", TEST_IMAGES[:large], dockerfile, { "large.txt" => @large_content })
  end

  # --- Tests ---

  def test_image_exists
    assert PodmanManager::image_exists?(TEST_IMAGES[:exit]),
           "Expected image '#{TEST_IMAGES[:exit]}' to exist"
    assert PodmanManager::image_exists?(TEST_IMAGES[:loop]),
           "Expected image '#{TEST_IMAGES[:loop]}' to exist"
    refute PodmanManager::image_exists?("nonexistent/image:latest"),
           "Expected nonexistent image to not exist"
  end

  def test_create_and_start_container
    # Test with long-running container
    container = PodmanManager::create_container(image: TEST_IMAGES[:loop], name: "test_loop_container")
    assert_instance_of PodmanManager::Container, container, "Expected a Container object from create_container"

    container.start
    assert_equal "running", container.status, "Expected container to be running after start"

    container.stop
    assert_equal "exited", container.status, "Expected container to be exited after stop"

    container.remove
    refute container.exists?, "Expected container to not exist after removal"

    # Test with quick-exit container
    container = PodmanManager::create_container(image: TEST_IMAGES[:exit], name: "test_exit_container")
    container.start
    sleep(1) # Allow time for the quick-exit container to finish
    assert_equal "exited", container.status, "Expected quick-exit container to be exited"
    container.remove
  end

  def test_container_stats
    container = PodmanManager::create_container(image: TEST_IMAGES[:loop], name: "test_stats_container")
    container.start

    sleep(3)

    assert_equal "running", container.status, "Container must be running to get stats"

    stats = container.stats
    assert_instance_of PodmanManager::ContainerStats, stats, "Expected stats to be a ContainerStats object"
    assert_kind_of Float, stats.cpu_percentage, "CPU percentage should be a Float"
    assert_kind_of Float, stats.memory_usage, "Memory usage should be a Float"
    assert_operator stats.cpu_percentage, :>=, 0.0, "CPU percentage should be non-negative"
    assert_operator stats.memory_usage, :>=, 0.0, "Memory usage should be non-negative"

    # Test stats normalization separately
    raw_stats = { "CPUPerc" => "5.00%", "MemUsage" => "10.5MiB / 100MiB" }
    normalized_stats = PodmanManager::ContainerStats.new(raw_stats)
    assert_equal 5.0, normalized_stats.cpu_percentage, "Normalized CPU percentage should be 5.0"
    assert_equal 10.5, normalized_stats.memory_usage, "Normalized memory usage should be 10.5"

    # Verify error when container is stopped
    container.stop
    assert_raises(PodmanManager::CommandError, "Expected error when getting stats for stopped container") do
      container.stats
    end

    container.remove
  end

  def test_aggregated_stats_for_image
    containers = 2.times.map do |i|
      container = PodmanManager::create_container(image: TEST_IMAGES[:loop], name: "test_agg_container_#{i}")
      container.start
      assert_equal "running", container.status, "Container must be running for aggregated stats"
      container
    end

    stats = PodmanManager::aggregated_stats_for_image(TEST_IMAGES[:loop])
    assert_includes stats, "aggregated", "Missing 'aggregated' key in stats"
    assert_includes stats["aggregated"], "cpu", "Missing 'cpu' in aggregated stats"
    assert_includes stats["aggregated"], "memory", "Missing 'memory' in aggregated stats"

    assert_kind_of Float, stats["aggregated"]["cpu"], "Aggregated CPU stat should be a Float"
    assert_kind_of Float, stats["aggregated"]["memory"], "Aggregated memory stat should be a Float"
    assert_operator stats["aggregated"]["cpu"], :>=, 0.0, "Aggregated CPU stat should be non-negative"
    assert_operator stats["aggregated"]["memory"], :>=, 0.0, "Aggregated memory stat should be non-negative"

    assert_includes stats, "containers", "Missing 'containers' key in stats"
    assert_equal containers.length, stats["containers"].size, "Number of containers in stats should match created containers"

    containers.each do |container|
      container.stop
      container.remove
    end
  end

  def test_with_container_block
    container_ref = nil
    PodmanManager::with_container(image: TEST_IMAGES[:exit], name: "test_with_container") do |container|
      assert_instance_of PodmanManager::Container, container, "Expected with_container to yield a Container object"
      assert container.exists?, "Expected container to exist within with_container block"
      container_ref = container
    end

    refute container_ref.exists?, "Expected container to be removed after with_container block"
  end

  def test_file_operations
    container = PodmanManager::create_container(image: TEST_IMAGES[:file], name: "test_file_ops")
    container.start

    assert container.file_exists?("/etc/test.txt"), "Expected /etc/test.txt to exist in container"
    refute container.file_exists?("/nonexistent.txt"), "Expected /nonexistent.txt to not exist in container"

    content = container.read_file("/etc/test.txt")
    assert_equal "hello world", content.strip, "Expected /etc/test.txt to contain 'hello world'"

    container.stop
    container.remove
  end

  def test_special_chars_file
    container = PodmanManager::create_container(image: TEST_IMAGES[:special], name: "test_special_chars")
    container.start

    content = container.read_file("/etc/special.txt")
    assert_equal @special_content, content, "Expected file content with special characters to match"

    container.stop
    container.remove
  end

  def test_large_file
    container = PodmanManager::create_container(image: TEST_IMAGES[:large], name: "test_large_file")
    container.start

    content = container.read_file("/etc/large.txt")
    assert_equal @large_content.length, content.length, "Expected large file content length to match"

    container.stop
    container.remove
  end

  def test_error_handling
    # Test non-existent container error
    assert_raises(PodmanManager::ContainerNotFoundError) do
      PodmanManager::Container.new("nonexistent", PodmanManager).status
    end

    # Test invalid image error
    assert_raises(PodmanManager::CommandError) do
      PodmanManager::create_container(image: "nonexistent:latest")
    end

    # Test cleanup with with_container when an error is raised inside the block
    assert_raises(RuntimeError) do
      PodmanManager::with_container(image: TEST_IMAGES[:exit]) do |container|
        raise RuntimeError, "Test error"
      end
    end

    # Verify that no containers remain for the test exit image
    containers = PodmanManager::container_ids_by_image(TEST_IMAGES[:exit])
    assert_empty containers, "Expected no containers to remain after error in with_container"
  end

  def test_podman_command_builder
    cmd = PodmanManager::PodmanCommand.new("create")
          .add_flag("-d")
          .add_option("name", "test_container")
          .add_option("memory", "512m")
          .add_argument(TEST_IMAGES[:exit])
          .build
    expected = ["podman", "create", "-d", "--name", "test_container", "--memory", "512m", TEST_IMAGES[:exit]]
    assert_equal expected, cmd, "PodmanCommand builder did not produce expected command array"

    # Test option name formatting with symbol keys
    cmd = PodmanManager::PodmanCommand.new("run")
          .add_option(:memory_swap, "1g")
          .build
    assert_equal ["podman", "run", "--memory-swap", "1g"], cmd, "Option name formatting failed"

    # Test method chaining for stats command
    cmd = PodmanManager::PodmanCommand.new("stats")
          .add_argument("container_id")
          .add_option("no-stream", true)
          .add_option("format", "json")
          .build
    expected = ["podman", "stats", "container_id", "--no-stream", "true", "--format", "json"]
    assert_equal expected, cmd, "PodmanCommand chaining did not produce expected command"
  end
end
