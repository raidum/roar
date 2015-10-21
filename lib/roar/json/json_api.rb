require 'roar/json'
require 'roar/decorator'

module Roar
  module JSON
    module JSONAPI
      def self.included(base)
        base.class_eval do
          include Representable::JSON
          include Roar::JSON::JSONAPI::Singular
          include Roar::JSON::JSONAPI::Resource
          include Roar::JSON::JSONAPI::Document

          extend ForCollection

          # representable_attrs[:resource_representer] = Class.new(Resource::Representer)

          private
            def create_representation_with(doc, options, format)
              super(doc, options.merge(:only_body => true), format)
            end
        end
      end

      module ForCollection
        def for_collection # same API as representable. TODO: we could use ::collection_representer! here.
          singular = self # e.g. Song::Representer

          # this basically does Module.new { include Hash::Collection .. }
          build_inline(nil, [Representable::Hash::Collection, Document::Collection, Roar::JSON, Roar::JSON::JSONAPI, Roar::Hypermedia], "", {}) do
            items extend: singular, :parse_strategy => :sync

            representable_attrs[:resource_representer] = singular.representable_attrs[:resource_representer]
            representable_attrs[:meta_representer]     = singular.representable_attrs[:meta_representer] # DISCUSS: do we need that?
            representable_attrs[:_wrap] = singular.representable_attrs[:_wrap]
            representable_attrs[:_href] = singular.representable_attrs[:_href]
          end
        end
      end


      module Singular
        def from_hash(hash, options={})
          hash["_links"] = hash["links"]
          super
        end
      end


      module Resource
        def self.included(base)
          base.extend Declarative # inject our ::link.
        end

        # New API for JSON-API representers.
        module Declarative
          def type(name=nil)
            return super unless name # original name.
            representable_attrs[:_wrap] = name.to_s
          end

          def href(name=nil)
            representable_attrs[:_href] = name.to_s
          end

          # Per-model links.
          def links(&block)
            nested(:_links, :inherit => true, &block)
          end

          # TODO: always create _links.
          def has_one(name)
            property :_links, :inherit => true, :use_decorator => true do # simply extend the Decorator _links.
              property "#{name}_id", :as => name
            end
          end

          def has_many(name)
            property :_links, :inherit => true, :use_decorator => true do # simply extend the Decorator _links.
              collection "#{name.to_s.sub(/s$/, "")}_ids", :as => name
            end
          end

          def compound(&block)
            nested(:included, &block)
          end

          def meta(&block)
            representable_attrs[:meta_representer] = Class.new(Roar::Decorator, &block)
          end
        end
      end


      # TODO: don't use Document for singular+wrap AND singular in collection (this way, we can get rid of the only_body)
      module Document
        def to_hash(options={})
          # per resource:
          res = super # render single resource or collection.
          # return res if options[:only_body]
          to_document(res, options)
        end

        def from_hash(hash, options={})

          return super(hash, options) if options[:only_body] # singular

          super(from_document(hash)) # singular
        end

      private
        def to_document(res, options)
          links = render_links(res, options)
          meta  = render_meta(options)

          puts "$$$$$$$$#TODO"
          require "pp"
          pp res

          compound      = render_compound(res)
          relationships = render_relationships!(res)

          # if res.is_a?(Array)
          #   compound = collection_compound!(res, {})
          # else
            # compound = compile_compound!(res.delete("included"), {})
          # end

          document = {
            data: {
              type: representable_attrs[:_wrap],
              id: res.delete('id').to_s
            }
          }
          document[:data].merge!(attributes: res) unless res.empty?
          document[:data][:relationships] = relationships if relationships and relationships.any?


          document.tap do |doc|
            doc[:data].merge!(links: links) unless links.empty?
            doc.merge!(meta)
            # doc.merge!("included" => compound) if compound && compound.size > 0 # FIXME: make that like the above line.
          end
        end

        def collection_item_to_document(res, options)
          # require "pry"; binding.pry
          meta  = render_meta(options)
          relationships = render_relationships!(res)
          res = remove_relationships(res)
          # FIXME: provide two different #to_document

          if res.is_a?(Array)
            compound = collection_compound!(res, {})
          else
            compound = compile_compound!(res.delete("linked"), {})
          end

          # require "pry"; binding.pry
          document = {
            type: representable_attrs[:_wrap],
            id: res.delete(:id).to_s
          }
          document.tap do |doc|
            doc.merge!(attributes: res) unless res.empty?
            # doc[:data].merge!(relationships: relationships) unless relationships.empty?
            doc.merge!(meta)
            doc.merge!("linked" => compound) if compound && compound.size > 0 # FIXME: make that like the above line.
          end
        end

        def from_document(hash)
          # hash[representable_attrs[:_wrap]]
          raise Exception.new('Unknown Type') unless hash['data']['type'] == representable_attrs[:_wrap]

          # hash: {"data"=>{"type"=>"articles", "attributes"=>{"title"=>"Ember Hamster"}, "relationships"=>{"author"=>{"data"=>{"type"=>"people", "id"=>"9"}}}}}
          attributes = hash["data"]["attributes"] || {}

          hash["data"]["relationships"].each do |rel, fragment| # FIXME: what if nil?
            attributes[rel] = fragment["data"] # DISCUSS: we could use a relationship representer here (but only if needed elsewhere).
          end

          # this is the format the object representer understands.
          attributes # {"title"=>"Ember Hamster", "author"=>{"type"=>"people", "id"=>"9"}}
        end

        # Compiles the linked: section for compound objects in the document.
        def collection_compound!(collection, compound)
          collection.each { |res|
            kv = res.delete("linked") or next

            compile_compound!(kv, compound)
          }

          compound
        end

        # Go through {"album"=>{"title"=>"Hackers"}, "musicians"=>[{"name"=>"Eddie Van Halen"}, ..]} from linked:
        # and wrap every item in an array.
        def render_compound(hash)
          return unless compound = hash.delete("included")
          # raise compound.inspect


          compound
        end

        def render_links(res, options)
          (res.delete("links") || []).collect { |link| [link["rel"], link["href"]] }.to_h
        end

        def render_meta(options)
          # TODO: this will call collection.page etc, directly on the collection. we could allow using a "meta"
          # object to hold this data.
          # `meta call_meta: true` or something
          return {"meta" => options["meta"]} if options["meta"]
          return {} unless representer = representable_attrs[:meta_representer]
          {"meta" => representer.new(represented).extend(Representable::Hash).to_hash}
        end

        def render_relationships!(res)
          (res["relationships"] || []).each do |name, hash|
            if hash.is_a?(Hash)
              hash[:links] = hash[:data].delete(:links)
            else # hash => [{data: {}}, ..]
              hash.each do |hsh|
                res["relationships"][name] = collection = {data: []}
                collection[:links] = hsh[:data].delete(:links) # FIXME: this is horrible.
                collection[:data] << hsh[:data]
              end
            end
          end
          res.delete("relationships")
        end


        module Collection
          include Document

          def to_hash(options={})
            # res = super(options.merge(:only_body => true))
            doc = {
              links: { self: representable_attrs[:_href] }
            }
            items = []

            decorated.each do |item|
              # to_document()
              items << collection_item_to_document(item, options.merge({collection_item: true}))
            end
            doc[:data] = items
            doc
          end

          def from_hash(hash, options={})
            hash = from_document(hash)
            super(hash, options.merge(:only_body => true))
          end
        end
      end
    end
  end
end
