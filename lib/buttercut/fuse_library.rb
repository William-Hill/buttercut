require 'json'

class ButterCut
  class FuseLibrary
    REQUIRED_MANIFEST_KEYS = %w[name version description params].freeze
    PARAM_TYPES = %w[number integer string boolean].freeze

    def self.load(root:)
      new(root: root).load
    end

    def initialize(root:)
      raise ArgumentError, "root required" if root.nil? || root.to_s.empty?
      @root = root
      @by_name = {}
    end

    def load
      return self unless Dir.exist?(@root)
      Dir.glob(File.join(@root, '*', 'manifest.json')).sort.each do |manifest_path|
        manifest = JSON.parse(File.read(manifest_path))
        validate_manifest!(manifest, manifest_path)
        name = manifest['name']
        if @by_name.key?(name)
          raise ArgumentError, "duplicate fuse name #{name.inspect} (in #{manifest_path})"
        end
        manifest['fuse_path'] = File.join(File.dirname(manifest_path), "#{name}.fuse")
        @by_name[name] = manifest.freeze
      end
      freeze
    end

    def lookup(name)
      @by_name[name]
    end

    def each(&block)
      @by_name.each_value(&block)
    end

    def names
      @by_name.keys
    end

    def validate_params!(fuse_name, params)
      manifest = lookup(fuse_name)
      raise ArgumentError, "unknown fuse #{fuse_name.inspect}" if manifest.nil?
      params ||= {}
      raise ArgumentError, "fuse #{fuse_name} params must be a hash" unless params.is_a?(Hash)
      declared = manifest['params'].each_with_object({}) { |p, h| h[p['name']] = p }
      params.each do |key, value|
        decl = declared[key]
        raise ArgumentError, "fuse #{fuse_name}: unknown param #{key.inspect}" if decl.nil?
        validate_param_value!(fuse_name, key, decl, value)
      end
    end

    private

    def validate_manifest!(manifest, path)
      missing = REQUIRED_MANIFEST_KEYS - manifest.keys
      unless missing.empty?
        raise ArgumentError, "manifest #{path} missing keys: #{missing.inspect}"
      end
      unless manifest['params'].is_a?(Array)
        raise ArgumentError, "manifest #{path} params must be an array"
      end
      manifest['params'].each do |p|
        unless p.is_a?(Hash) && p['name'].is_a?(String) && PARAM_TYPES.include?(p['type'])
          raise ArgumentError, "manifest #{path} param invalid: #{p.inspect}"
        end
      end
    end

    def validate_param_value!(fuse_name, key, decl, value)
      case decl['type']
      when 'number'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be number, got #{value.class}" unless value.is_a?(Numeric)
        if decl['range'].is_a?(Array) && decl['range'].length == 2
          lo, hi = decl['range']
          unless value >= lo && value <= hi
            raise ArgumentError, "fuse #{fuse_name}: param #{key} out of range (#{lo}..#{hi}), got #{value}"
          end
        end
      when 'integer'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be integer, got #{value.class}" unless value.is_a?(Integer)
      when 'string'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be string, got #{value.class}" unless value.is_a?(String)
      when 'boolean'
        unless value == true || value == false
          raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be boolean, got #{value.class}"
        end
      end
    end
  end
end
