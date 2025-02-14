Gem::Specification.new do |spec|
  spec.name          = 'podman-manager'
  spec.version       = '0.1.0'
  spec.authors       = ['Pedro Navajas Modelo']
  spec.email         = ['navajas@modelo.solutions']

  spec.summary       = 'Gestión de Podman'
  spec.description   = 'Una gema para facilitar la gestión de Podman (IA)'
  spec.homepage      = 'https://github.com/modelodev/podman-manager'
  spec.license       = 'MIT'

  spec.files         = Dir['lib/**/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'some_dependency'
end

