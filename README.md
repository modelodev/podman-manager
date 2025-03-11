# PodmanManager

A Ruby wrapper for the Podman container engine that provides a clean, object-oriented interface for managing containers.

[![Gem Version](https://badge.fury.io/rb/podman-manager.svg)](https://rubygems.org/gems/podman-manager)

## Features

- Create, run, stop, and remove containers
- Execute commands in containers
- Read files from containers
- Get container stats
- Work with container images
- Robust error handling
- Timeout management for container operations
- Support for Base64-encoded container labels

## Installation

Add this to your Gemfile:

```ruby
gem 'podman-manager'
```

And then execute:

```
$ bundle install
```

Or install it directly:

```
$ gem install podman-manager
```

## Requirements

- Ruby 2.5 or higher
- Podman installed on your system

## Usage

### Basic Container Operations

```ruby
require 'podman-manager'

# Initialize with a custom logger (optional)
PodmanManager.initialize(Logger.new(STDOUT))

# Check if an image exists
if PodmanManager.image_exists?("alpine:latest")
  puts "Alpine image exists"
end

# Create and run a container
container = PodmanManager.run_container(
  image: "alpine:latest",
  name: "my_container"
)

# Check container status
puts container.status  # => "running"

# Execute a file read operation
if container.file_exists?("/etc/hostname")
  hostname = container.read_file("/etc/hostname")
  puts "Container hostname: #{hostname}"
end

# Get container resource stats
stats = container.stats
puts "CPU: #{stats.cpu_percentage}%, Memory: #{stats.memory_usage}MB"

# Stop and remove the container
container.stop
container.remove
```

### Automatic Container Management

Use the `with_container` method to automatically create, start, and clean up a container:

```ruby
# Container is automatically removed when the block exits, even if an error occurs
PodmanManager.with_container(image: "alpine:latest", name: "temp_container") do |container|
  container.start
  
  # Work with the container
  output = container.read_file("/etc/alpine-release")
  puts "Alpine version: #{output}"
  
  # Any error here won't leave containers behind
end
```

### Advanced Container Configuration

```ruby
# Run a container with custom command and security options
container = PodmanManager.run_container(
  image: "nginx:latest",
  name: "secure_nginx",
  network: "host",
  env: "ENV_VAR=value",
  volume: "/host/path:/container/path",
  cap_drop: "ALL",
  security_opt: "no-new-privileges",
  read_only: "true",
  user: "nginx",
  workdir: "/app"
)
```

### Container Stats Collection

```ruby
# Get stats for a single container
container = PodmanManager.run_container(image: "alpine:latest", name: "stats_test")
stats = container.stats
puts "Container stats:"
puts "  CPU: #{stats.cpu_percentage}%"
puts "  Memory: #{stats.memory_usage}MB"

# Get aggregated stats for all containers of a specific image
stats = PodmanManager.aggregated_stats_for_image("my-service:latest")
puts "Total CPU usage: #{stats['aggregated']['cpu']}%"
puts "Total memory usage: #{stats['aggregated']['memory']}MB"
puts "Active containers: #{stats['containers'].length}"
```

### Reading Base64-encoded Container Labels

```ruby
# Read a label directly
label = PodmanManager.read_label("my-image:latest", "org.label-schema.version")
puts "Image version: #{label}"

# Read and decode a Base64-encoded label (e.g., for configuration data)
manifest = PodmanManager.read_label("my-image:latest", "app.manifest", decode: true)
puts "Decoded manifest: #{manifest}"
```

### Error Handling

PodmanManager provides specific error classes for better error handling:

```ruby
begin
  container = PodmanManager::Container.new("nonexistent-id", PodmanManager)
  container.status
rescue PodmanManager::ContainerNotFoundError => e
  puts "Container not found: #{e.message}"
rescue PodmanManager::TimeoutError => e
  puts "Operation timed out: #{e.message}"
rescue PodmanManager::CommandError => e
  puts "Command failed: #{e.message}"
rescue PodmanManager::PodmanError => e
  puts "Generic podman error: #{e.message}"
end
```

## Command Builder

PodmanManager provides a fluent interface for building Podman commands:

```ruby
cmd = PodmanManager::PodmanCommand.new("run")
  .add_flag("-d")
  .add_option("name", "my-container")
  .add_option("memory", "512m")
  .add_argument("alpine:latest")
  .add_argument("sleep")
  .add_argument("infinity")
  .build

# => ["podman", "run", "-d", "--name", "my-container", "--memory", "512m", "alpine:latest", "sleep", "infinity"]
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

MIT