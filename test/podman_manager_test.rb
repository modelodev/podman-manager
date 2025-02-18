require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'logger'
require_relative '../lib/podman-manager'  # Ensure PodmanManager is in this file

# Test suite for PodmanManager
class TestPodmanManager < Minitest::Test
  # Setup the testing environment:
  # - Create a PodmanManager instance.
  # - Create temporary directories for two Dockerfiles.
  # - Build two images: one for an exiting container and one for a looping container.
  def setup
    @temp_dirs = {}
    @special_content = "Hello\nWorld\n测试\n€\n"
    @large_content = "x" * 1_000_000
    build_images
  end

  # Cleanup temporary directories and remove test images.
  def teardown
    @temp_dirs.each_value do |dir|
      FileUtils.remove_entry(dir) if Dir.exist?(dir)
    end
    [
      'test/hola_exit:latest',
      'test/hola_loop:latest',
      'test/file_test:latest',
      'test/special_chars:latest',
      'test/large_file:latest'
    ].each { |image| remove_test_image(image) }
  end

  # Build the two test images using temporary Dockerfile contexts.
  def build_images
    # Build the "hola_exit" image (prints "hola" and terminates)
    exit_dir = Dir.mktmpdir("hola_exit")
    @temp_dirs[:hola_exit] = exit_dir
    File.write(File.join(exit_dir, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:latest
      CMD echo "hola"
    DOCKERFILE
    build_image(exit_dir, "test/hola_exit:latest")

    # Build the "hola_loop" image (prints "hola" every 5 seconds indefinitely)
    loop_dir = Dir.mktmpdir("hola_loop")
    @temp_dirs[:hola_loop] = loop_dir
    File.write(File.join(loop_dir, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:latest
      CMD sh -c 'while true; do echo "hola"; sleep 5; done'
    DOCKERFILE
    build_image(loop_dir, "test/hola_loop:latest")

    # Build image with test file
    file_test_dir = Dir.mktmpdir("file_test")
    @temp_dirs[:file_test] = file_test_dir
    File.write(File.join(file_test_dir, "test.txt"), "hello world")
    File.write(File.join(file_test_dir, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:latest
      COPY test.txt /etc/test.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_image(file_test_dir, "test/file_test:latest")

    # Build image with special characters file
    special_chars_dir = Dir.mktmpdir("special_chars_test")
    @temp_dirs[:special_chars_test] = special_chars_dir
    @special_content = "Hello\nWorld\n测试\n€\n"
    File.write(File.join(special_chars_dir, "special.txt"), @special_content)
    File.write(File.join(special_chars_dir, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:latest
      COPY special.txt /etc/special.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_image(special_chars_dir, "test/special_chars:latest")

    # Build image with large file
    large_file_dir = Dir.mktmpdir("large_file_test")
    @temp_dirs[:large_file_test] = large_file_dir
    @large_content = "x" * 1_000_000
    File.write(File.join(large_file_dir, "large.txt"), @large_content)
    File.write(File.join(large_file_dir, "Dockerfile"), <<~DOCKERFILE)
      FROM alpine:latest
      COPY large.txt /etc/large.txt
      CMD ["tail", "-f", "/dev/null"]
    DOCKERFILE
    build_image(large_file_dir, "test/large_file:latest")
  end

  # Helper to build a Podman image given a build context and tag.
  def build_image(context_dir, image_tag)
    cmd = ["podman", "build", "-t", image_tag, context_dir]
    stdout, stderr, status = Open3.capture3(*cmd)
    raise "Failed to build image #{image_tag}: #{stderr}" unless status.success?
  end

  # Helper to remove a test image if it exists.
  def remove_test_image(image_tag)
    cmd = ["podman", "rmi", "-f", image_tag]
    Open3.capture3(*cmd)
  end

  # ----------------------------------------------------------------------------
  # Tests begin here. Each test is described in clear English.
  # ----------------------------------------------------------------------------

  # Test that the image_exists? method correctly identifies images.
  def test_image_exists
    assert PodmanManager::image_exists?("test/hola_exit:latest"), "Expected image 'test/hola_exit:latest' to exist"
    assert PodmanManager::image_exists?("test/hola_loop:latest"), "Expected image 'test/hola_loop:latest' to exist"
    refute PodmanManager::image_exists?("nonexistent/image:latest"), "Expected nonexistent image to not exist"
  end

  # Test creating a container from the hola_exit image, starting it,
  # and verifying that it prints "hola" then exits.
  def test_create_and_start_exit_container
    container_id = PodmanManager.create_container(image: "test/hola_exit:latest", name: "test_exit_container")
    PodmanManager.start_container(container_id)
    # Wait until the container reaches the "exited" status.
    PodmanManager.wait_for_status(container_id, "exited", timeout: 10, interval: 1)
    status = PodmanManager.container_status(container_id)
    assert_equal "exited", status, "Expected container to be exited"

    # Capture logs to verify output contains "hola"
    logs = []
    PodmanManager.stream_container_logs(container_id, follow: false) do |line, stream|
      logs << line if stream == :stdout
    end
    assert_includes logs.join, "hola", "Expected logs to include 'hola'"

    PodmanManager.remove_container(container_id)
  end

  # Test starting a container from the hola_loop image, ensuring it is running,
  # then stopping it and verifying its status becomes "exited".
  def test_start_and_stop_loop_container
    container_id = PodmanManager.create_container(image: "test/hola_loop:latest", name: "test_loop_container")
    PodmanManager.start_container(container_id)
    status = PodmanManager.container_status(container_id)
    assert_equal "running", status, "Expected container to be running"
    PodmanManager.wait_for_status(container_id, "running", timeout: 5, interval: 1)
    PodmanManager.stop_container(container_id)
    PodmanManager.wait_for_status(container_id, "exited", timeout: 10, interval: 1)
    status_after_stop = PodmanManager.container_status(container_id)
    assert_equal "exited", status_after_stop, "Expected container to be exited after stop"
    PodmanManager.remove_container(container_id)
  end

  # Test that with_container initializes a container, yields its ID,
  # and then cleans it up (stopping and removing it) after the block finishes.
  def test_with_container_cleanup
    container_id = nil
    PodmanManager.with_container(image: "test/hola_exit:latest", name: "test_with_container") do |id|
      container_id = id
      assert PodmanManager.container_exists?(id), "Expected container to exist within with_container block"
    end
    refute PodmanManager.container_exists?(container_id), "Expected container to be removed after with_container block"
  end

  # Test retrieving container statistics from a running hola_loop container.
  def test_container_stats
    container_id = PodmanManager.create_container(image: "test/hola_loop:latest", name: "test_stats_container")
    PodmanManager.start_container(container_id)
    sleep 3  # Allow additional time for stats to become available
    stats = PodmanManager.container_stats(container_id)
    assert stats.is_a?(Hash), "Expected container stats to be a Hash"
    assert stats.key?("cpu"), "Expected container stats to include 'cpu'"
    assert stats.key?("mem_usage") || stats.key?("memory"), "Expected container stats to include 'mem_usage' or 'memory'"
    PodmanManager.stop_container(container_id)
    PodmanManager.remove_container(container_id)
  end

  # Test aggregating statistics for all containers from the hola_loop image.
  def test_aggregated_stats_for_image
    container_ids = []
    2.times do
      container_id = PodmanManager.create_container(image: "test/hola_loop:latest")
      container_ids << container_id
      PodmanManager.start_container(container_id)
    end
    sleep 3  # Allow containers to generate stats
    aggregated = PodmanManager.aggregated_stats_for_image("test/hola_loop:latest")
    assert aggregated.is_a?(Hash), "Expected aggregated stats to be a Hash"
    assert aggregated.key?("aggregated"), "Expected aggregated stats to have an 'aggregated' key"
    assert_kind_of Numeric, aggregated["aggregated"]["cpu"], "Expected aggregated CPU to be numeric"
    assert_kind_of Numeric, aggregated["aggregated"]["memory"], "Expected aggregated memory to be numeric"
    container_ids.each do |id|
      PodmanManager.stop_container(id)
      PodmanManager.remove_container(id)
    end
  end

  # Test that streaming container logs yields the expected output.
  def test_stream_container_logs
    container_id = PodmanManager.create_container(image: "test/hola_exit:latest", name: "test_logs_container")
    PodmanManager.start_container(container_id)
    logs = []
    PodmanManager.stream_container_logs(container_id, follow: false) do |line, stream|
      logs << line if stream == :stdout
    end
    assert logs.any? { |line| line.include?("hola") }, "Expected logs to include 'hola'"
    PodmanManager.remove_container(container_id)
  end

  # Test that wait_for_status raises a timeout error when the desired status is not reached.
  def test_wait_for_status_timeout
    container_id = PodmanManager.create_container(image: "test/hola_loop:latest", name: "test_timeout_container")
    PodmanManager.start_container(container_id)
    assert_raises(PodmanManager::PodmanError, "Expected timeout error when waiting for status that never occurs") do
      PodmanManager.wait_for_status(container_id, "exited", timeout: 3, interval: 1)
    end
    PodmanManager.stop_container(container_id)
    PodmanManager.remove_container(container_id)
  end

  # Test error handling for operations on a nonexistent container.
  def test_error_handling_for_nonexistent_container
    fake_id = "nonexistent_container_id"
    refute PodmanManager.container_exists?(fake_id), "Expected container to not exist"
    assert_nil PodmanManager.container_status(fake_id), "Expected container_status to return nil for nonexistent container"
    assert_raises(PodmanManager::PodmanError, "Expected error when starting nonexistent container") do
      PodmanManager.start_container(fake_id)
    end
  end

  # Test that create_container yields output when a block is provided.
  def test_create_container_with_block
    lines = []
    container_id = PodmanManager.create_container(image: "test/hola_exit:latest", name: "test_block_container") do |line, stream|
      lines << line
    end
    refute_empty container_id, "Expected container id to be returned"
    assert lines.any?, "Expected create_container block to receive output lines"
    PodmanManager.remove_container(container_id)
  end

  # Test that start_container yields output when a block is provided.
  def test_start_container_with_block
    container_id = PodmanManager.create_container(image: "test/hola_exit:latest", name: "test_start_block_container")
    lines = []
    PodmanManager.start_container(container_id) do |line, stream|
      lines << line
    end
    assert lines.any?, "Expected start_container block to receive output lines"
    PodmanManager.remove_container(container_id)
  end

  # Test that stop_container yields output when a block is provided.
  def test_stop_container_with_block
    container_id = PodmanManager.create_container(image: "test/hola_loop:latest", name: "test_stop_block_container")
    PodmanManager.start_container(container_id)
    lines = []
    PodmanManager.stop_container(container_id) do |line, stream|
      lines << line
    end
    assert lines.any?, "Expected stop_container block to receive output lines"
    PodmanManager.remove_container(container_id)
  end

  # Test that remove_container yields output when a block is provided.
  def test_remove_container_with_block
    container_id = PodmanManager.create_container(image: "test/hola_exit:latest", name: "test_remove_block_container")
    lines = []
    PodmanManager.remove_container(container_id) do |line, stream|
      lines << line
    end
    assert lines.any?, "Expected remove_container block to receive output lines"
  end

  # Test file operations with containers
  def test_read_file_from_container
    # Probar lectura del fichero
    container_id = PodmanManager.create_container(image: "test/file_test:latest")
    begin
      PodmanManager.start_container(container_id)
      # Test successful file read
      content = PodmanManager.read_file(container_id, "/etc/test.txt")
      assert_equal "hello world", content.strip, "Expected file content to match"

      # Test reading non-existent file
      content = PodmanManager.read_file(container_id, "/etc/nonexistent.txt")
      assert_nil content, "Expected nil when reading non-existent file"
    ensure
      PodmanManager.stop_container(container_id) rescue nil
      PodmanManager.remove_container(container_id)
      remove_test_image("test/file_test:latest")
    end
  end

  def test_file_exists_in_container
    # Probar existencia de ficheros
    container_id = PodmanManager.create_container(image: "test/file_test:latest")
    begin
      PodmanManager.start_container(container_id)
      # Test existing file
      assert PodmanManager.file_exists?(container_id, "/etc/test.txt"), 
             "Expected /etc/test.txt to exist in container"

      # Test non-existent file
      refute PodmanManager.file_exists?(container_id, "/etc/nonexistent.txt"), 
             "Expected /etc/nonexistent.txt to not exist in container"

      # Test with invalid container ID
      refute PodmanManager.file_exists?("invalid_container", "/etc/test.txt"), 
             "Expected file_exists? to return false with invalid container"
    ensure
      PodmanManager.stop_container(container_id) rescue nil
      PodmanManager.remove_container(container_id)
      remove_test_image("test/file_test:latest")
    end
  end

  def test_read_file_with_special_characters
    # Probar lectura del fichero con caracteres especiales
    container_id = PodmanManager.create_container(image: "test/special_chars:latest")
    begin
      PodmanManager.start_container(container_id)
      content = PodmanManager.read_file(container_id, "/etc/special.txt")
      assert_equal @special_content, content, 
                   "Expected file content with special characters to match"
    ensure
      PodmanManager.stop_container(container_id) rescue nil
      PodmanManager.remove_container(container_id)
      remove_test_image("test/special_chars:latest")
    end
  end

  def test_read_large_file
    # Probar lectura del fichero grande
    container_id = PodmanManager.create_container(image: "test/large_file:latest")
    begin
      PodmanManager.start_container(container_id)
      content = PodmanManager.read_file(container_id, "/etc/large.txt")
      assert_equal @large_content.length, content.length, 
                   "Expected large file content length to match"
    ensure
      PodmanManager.stop_container(container_id) rescue nil
      PodmanManager.remove_container(container_id)
      remove_test_image("test/large_file:latest")
    end
  end
end
