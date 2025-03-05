require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'logger'
require 'base64'
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

  # Variables de clase para construir imágenes solo una vez.
  @images_built    = false
  @temp_dirs       = {}
  @special_content = "Hello\nWorld\n测试\n€\n"
  @large_content   = "x" * 1_000_000

  class << self
    attr_accessor :images_built, :temp_dirs, :special_content, :large_content

    # Método para construir todas las imágenes de prueba.
    def build_all_images
      build_exit_image
      build_loop_image
      build_file_test_image
      build_special_chars_image
      build_large_file_image
    end

    # Crea una imagen en un directorio temporal.
    # files: hash con rutas relativas y contenido.
    def build_temp_image(prefix, image_tag, dockerfile, files = {})
      dir = Dir.mktmpdir(prefix)
      temp_dirs[prefix.to_sym] = dir
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
      build_temp_image("special_chars_test", TEST_IMAGES[:special], dockerfile, { "special.txt" => special_content })
    end

    def build_large_file_image
      dockerfile = <<~DOCKERFILE
        FROM alpine:latest
        COPY large.txt /etc/large.txt
        CMD ["tail", "-f", "/dev/null"]
      DOCKERFILE
      build_temp_image("large_file_test", TEST_IMAGES[:large], dockerfile, { "large.txt" => large_content })
    end
  end

  # Helpers para reducir duplicación en tests
  def create_running_container(image, name = nil)
    name ||= "test_container_#{Time.now.to_i}_#{rand(1000)}"
    container = PodmanManager.create_container(image: image, name: name)
    container.start
    container
  end

  def with_running_container(image, name = nil, &block)
    container = create_running_container(image, name)
    begin
      yield(container)
    ensure
      cleanup_container(container)
    end
  end

  def cleanup_container(container)
    return unless container.exists?
    container.stop if container.status == "running"
    container.remove(force: true)
  end

  # Se ejecuta antes de cada prueba.
  # Se verifica si las imágenes ya fueron construidas; de lo contrario se construyen.
  def setup
    unless self.class.images_built
      self.class.build_all_images
      self.class.images_built = true
    end
    # Asignamos variables de instancia para facilitar el acceso
    @special_content = self.class.special_content
    @large_content   = self.class.large_content
    
    # Asegurar que el CommandRunner esté inicializado para cada test
    PodmanManager.initialize(Logger.new(nil)) # Logger silencioso para tests
  end

  # No se eliminan las imágenes en cada teardown, ya que se quiere mantenerlas
  # durante toda la suite. La limpieza se realiza en Minitest.after_run.
  def teardown
    # Aquí se pueden limpiar contenedores u otros recursos creados en cada test.
  end

  # Limpieza global: se eliminan los directorios temporales y las imágenes creadas.
  Minitest.after_run do
    TestPodmanManager.temp_dirs.each_value do |dir|
      FileUtils.remove_entry(dir) if Dir.exist?(dir)
    end
    TEST_IMAGES.values.each { |tag| TestPodmanManager.remove_test_image(tag) }
  end

  # --- Tests ---

  def test_image_exists
    assert PodmanManager.image_exists?(TEST_IMAGES[:exit]),
           "Expected image '#{TEST_IMAGES[:exit]}' to exist"
    assert PodmanManager.image_exists?(TEST_IMAGES[:loop]),
           "Expected image '#{TEST_IMAGES[:loop]}' to exist"
    refute PodmanManager.image_exists?("nonexistent/image:latest"),
           "Expected nonexistent image to not exist"
  end

  def test_create_and_start_container
    # Test con contenedor de larga ejecución
    container = PodmanManager.create_container(image: TEST_IMAGES[:loop], name: "test_loop_container")
    assert_instance_of PodmanManager::Container, container, "Expected a Container object from create_container"

    container.start
    assert_equal "running", container.status, "Expected container to be running after start"

    container.stop
    assert_equal "exited", container.status, "Expected container to be exited after stop"

    container.remove
    refute container.exists?, "Expected container to not exist after removal"

    # Test con contenedor de rápida finalización
    container = PodmanManager.create_container(image: TEST_IMAGES[:exit], name: "test_exit_container")
    container.start
    sleep(1) # Permite que el contenedor de rápida finalización termine
    assert_equal "exited", container.status, "Expected quick-exit container to be exited"
    container.remove
  end

  def test_container_stats
    with_running_container(TEST_IMAGES[:loop], "test_stats_container") do |container|
      sleep(3)

      assert_equal "running", container.status, "Container must be running to get stats"

      stats = container.stats
      assert_instance_of PodmanManager::ContainerStats, stats, "Expected stats to be a ContainerStats object"
      assert_kind_of Float, stats.cpu_percentage, "CPU percentage should be a Float"
      assert_kind_of Float, stats.memory_usage, "Memory usage should be a Float"
      assert_operator stats.cpu_percentage, :>=, 0.0, "CPU percentage should be non-negative"
      assert_operator stats.memory_usage, :>=, 0.0, "Memory usage should be non-negative"

      # Test de normalización de stats
      raw_stats = { "CPUPerc" => "5.00%", "MemUsage" => "10.5MiB / 100MiB" }
      normalized_stats = PodmanManager::ContainerStats.new(raw_stats)
      assert_equal 5.0, normalized_stats.cpu_percentage, "Normalized CPU percentage should be 5.0"
      assert_equal 10.5, normalized_stats.memory_usage, "Normalized memory usage should be 10.5"
    end

    # Test error en container parado
    container = create_running_container(TEST_IMAGES[:exit])
    sleep(1) # Asegurar que termine
    assert_equal "exited", container.status, "Container should be exited for this test"
    
    assert_raises(PodmanManager::CommandError, "Expected error when getting stats for stopped container") do
      container.stats
    end
    
    cleanup_container(container)
  end

  def test_aggregated_stats_for_image
    containers = 2.times.map do |i|
      create_running_container(TEST_IMAGES[:loop], "test_agg_container_#{i}")
    end

    begin
      stats = PodmanManager.aggregated_stats_for_image(TEST_IMAGES[:loop])
      assert_includes stats, "aggregated", "Missing 'aggregated' key in stats"
      assert_includes stats["aggregated"], "cpu", "Missing 'cpu' in aggregated stats"
      assert_includes stats["aggregated"], "memory", "Missing 'memory' in aggregated stats"

      assert_kind_of Float, stats["aggregated"]["cpu"], "Aggregated CPU stat should be a Float"
      assert_kind_of Float, stats["aggregated"]["memory"], "Aggregated memory stat should be a Float"
      assert_operator stats["aggregated"]["cpu"], :>=, 0.0, "Aggregated CPU stat should be non-negative"
      assert_operator stats["aggregated"]["memory"], :>=, 0.0, "Aggregated memory stat should be non-negative"

      assert_includes stats, "containers", "Missing 'containers' key in stats"
      assert_equal containers.length, stats["containers"].size, "Number of containers in stats should match created containers"
    ensure
      containers.each { |container| cleanup_container(container) }
    end
  end

  def test_with_container_block
    container_ref = nil
    PodmanManager.with_container(image: TEST_IMAGES[:exit], name: "test_with_container") do |container|
      assert_instance_of PodmanManager::Container, container, "Expected with_container to yield a Container object"
      assert container.exists?, "Expected container to exist within with_container block"
      container_ref = container
    end

    refute container_ref.exists?, "Expected container to be removed after with_container block"
  end

  def test_file_operations
    with_running_container(TEST_IMAGES[:file], "test_file_ops") do |container|
      assert container.file_exists?("/etc/test.txt"), "Expected /etc/test.txt to exist in container"
      refute container.file_exists?("/nonexistent.txt"), "Expected /nonexistent.txt to not exist in container"

      content = container.read_file("/etc/test.txt")
      assert_equal "hello world", content.strip, "Expected /etc/test.txt to contain 'hello world'"
    end
  end

  def test_special_chars_file
    with_running_container(TEST_IMAGES[:special], "test_special_chars") do |container|
      content = container.read_file("/etc/special.txt")
      assert_equal @special_content, content, "Expected file content with special characters to match"
    end
  end

  def test_large_file
    with_running_container(TEST_IMAGES[:large], "test_large_file") do |container|
      content = container.read_file("/etc/large.txt")
      assert_equal @large_content.length, content.length, "Expected large file content length to match"
    end
  end

  def test_error_handling
    # Test para contenedor inexistente
    assert_raises(PodmanManager::ContainerNotFoundError) do
      PodmanManager::Container.new("nonexistent", PodmanManager).status
    end

    # Test para imagen inválida
    assert_raises(PodmanManager::CommandError) do
      PodmanManager.create_container(image: "nonexistent:latest")
    end

    # Test de limpieza con with_container cuando se lanza un error dentro del bloque
    assert_raises(RuntimeError) do
      PodmanManager.with_container(image: TEST_IMAGES[:exit]) do |container|
        raise RuntimeError, "Test error"
      end
    end

    # Verifica que no queden contenedores de la imagen de prueba exit
    containers = PodmanManager.container_ids_by_image(TEST_IMAGES[:exit])
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

    # Test con opción con key symbol y formato esperado
    cmd = PodmanManager::PodmanCommand.new("run")
          .add_option(:memory_swap, "1g")
          .build
    assert_equal ["podman", "run", "--memory-swap", "1g"], cmd, "Option name formatting failed"

    # Test encadenado de métodos para stats command
    cmd = PodmanManager::PodmanCommand.new("stats")
          .add_argument("container_id")
          .add_option("no-stream", true)
          .add_option("format", "json")
          .build
    expected = ["podman", "stats", "container_id", "--no-stream", "true", "--format", "json"]
    assert_equal expected, cmd, "PodmanCommand chaining did not produce expected command"
  end

  def test_command_runner
    runner = PodmanManager::CommandRunner.new
    
    # Test detección de contenedor no encontrado
    assert runner.container_not_found?("Error: no such container"), 
           "Should detect 'no such container' error"
    assert runner.container_not_found?("Error: no such object"),
           "Should detect 'no such object' error"
    refute runner.container_not_found?("Error: other error"),
           "Should not detect container not found for other errors"
    
    # Test ejecución básica de comandos
    cmd = ["echo", "test"]
    stdout, stderr, status = runner.run(cmd)
    assert_equal "test\n", stdout, "Command runner should capture stdout correctly"
    assert status.success?, "Echo command should succeed"
  end

  def test_read_label
    # Define the agent manifest YAML content.
    manifest_yaml = <<~YAML
      version: '1.0'
      description: "GPT-based processing agent"
      config:
        - name: NAME
          type: string
          required: true
          description: "Unique identifier for the agent instance"
        - name: PORT
          type: integer
          required: true
          default: 8989
          description: "Port where the agent listens"
    YAML

    # Encode the YAML content in Base64.
    encoded_manifest = Base64.strict_encode64(manifest_yaml)

    # Create a Dockerfile that sets a label with the Base64-encoded manifest.
    dockerfile = <<~DOCKERFILE
      FROM alpine:latest
      LABEL agent.manifest="#{encoded_manifest}"
      CMD ["echo", "hello"]
    DOCKERFILE

    # Build a temporary image with the agent.manifest label.
    self.class.build_temp_image("agent_manifest", "test/agent_manifest:latest", dockerfile)

    # Use the read_label method to retrieve and decode the label.
    manifest_read = PodmanManager.read_label("test/agent_manifest:latest", "agent.manifest", decode: true)
    assert_equal manifest_yaml.strip, manifest_read.strip, "The agent manifest should match the expected YAML"
  end

  def test_poll_with_timeout
    # Crear un contenedor para probar el método poll_with_timeout
    container = create_running_container(TEST_IMAGES[:loop])
    
    begin
      # Probar que poll_with_timeout retorna el resultado cuando la condición se cumple
      result = container.send(:poll_with_timeout, timeout: 1) do
        "success"
      end
      assert_equal "success", result, "poll_with_timeout should return result when block returns non-nil"
      
      # Probar que poll_with_timeout lanza TimeoutError cuando se agota el tiempo
      assert_raises(PodmanManager::TimeoutError) do
        container.send(:poll_with_timeout, timeout: 0.1) do
          nil # Nunca retorna un valor válido
        end
      end
    ensure
      cleanup_container(container)
    end
  end
  
  def test_run_container
    # Test de ejecución de contenedor directa
    container = PodmanManager.run_container(image: TEST_IMAGES[:loop], name: "test_run_container")
    assert_instance_of PodmanManager::Container, container, "Expected a Container object from run_container"
    assert_equal "running", container.status, "Container should be running after run_container"
    
    # Limpieza
    container.stop
    container.remove
    
    # Test con comandos personalizados
    custom_cmd = ["sh", "-c", "echo 'test command' > /tmp/test.txt && tail -f /dev/null"]
    container = PodmanManager.run_container(
      image: TEST_IMAGES[:file], 
      name: "test_run_with_cmd",
      command: custom_cmd
    )
    
    # Verificar que el comando se ejecutó
    sleep(1) # Dar tiempo para que el contenedor ejecute el comando
    assert container.file_exists?("/tmp/test.txt"), "Custom command did not execute correctly"
    content = container.read_file("/tmp/test.txt")
    assert_equal "test command", content.strip, "Custom command output does not match"
    
    # Limpieza
    container.stop
    container.remove
  end
  
  def test_run_container_with_advanced_options
    # Test con opciones avanzadas de seguridad y networking
    container = nil
    begin
      container = PodmanManager.run_container(
        image: TEST_IMAGES[:file],
        name: "test_advanced_options",
        cap_drop: "ALL",                    # --cap-drop ALL
        security_opt: "no-new-privileges",  # --security-opt no-new-privileges
        env: "TEST_VAR=test_value"          # --env TEST_VAR=test_value
      )
      
      assert_equal "running", container.status, "Container should be running with advanced options"
      
      # Verificar que las variables de entorno se configuraron correctamente
      env_test = container.read_file("/proc/self/environ")
      assert env_test.include?("TEST_VAR=test_value"), "Environment variable not set correctly"
    ensure
      # Limpieza
      if container && container.exists?
        container.stop if container.status == "running"
        container.remove
      end
    end
  end
  
  def test_stop_container
    # Crear un contenedor con un nombre específico
    container = PodmanManager.run_container(image: TEST_IMAGES[:loop], name: "test_stop_container")
    assert_equal "running", container.status, "Container should be running initially"
    
    # Detener el contenedor usando el método
    assert PodmanManager.stop_container(container.id), "stop_container should return true on success"
    assert_equal "exited", container.status, "Container should be exited after stop_container"
    
    # Verificar que detener un contenedor ya detenido funciona sin errores
    assert PodmanManager.stop_container(container.id), "stop_container should return true for already stopped container"
    
    # Verificar que detener un contenedor inexistente lanza ContainerNotFoundError
    container.remove
    assert_raises(PodmanManager::ContainerNotFoundError) do
      PodmanManager.stop_container(container.id)
    end
    
    # Verificar que podemos detener por nombre
    container = PodmanManager.run_container(image: TEST_IMAGES[:loop], name: "test_stop_by_name")
    assert PodmanManager.stop_container("test_stop_by_name"), "should stop container by name"
    assert_equal "exited", container.status, "Container should be exited after stop by name"
    container.remove
  end
end