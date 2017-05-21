require 'scraperwiki'
require 'mechanize'
require 'pry'
require 'reverse_markdown'
require 'active_support/inflector'
require 'nokogiri'
require 'time'
require 'addressable'
require 'json'
require 'httparty'
require 'logger'

def cache_index?
  if ENV['MORPH_CACHE_INDEX']
    ENV['MORPH_CACHE_INDEX'] =~ /true/i
  else
    true
  end
end

module PetRescue
  module Log
    LOGGER = Logger.new(STDOUT)

    def log_level
      if ENV['MORPH_LOG_LEVEL']
        begin
          ('Logger::' + ENV['MORPH_LOG_LEVEL'].upcase).constantize
        rescue NameError
          puts 'FATAL: Log level must be one of ' +
            Logger::Severity.constants.join(', ')
          exit(1)
        end
      else
        Logger::DEBUG
      end
    end

    def setup_logger
      @logger = LOGGER
      @logger.level = log_level
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime}: [#{severity}] #{msg}\n"
      end
    end

    def log
      setup_logger unless @logger
      @logger
    end
  end

  class Scraped
    include Log

    def new_animals(other_animals)
      other_animals.select {|r| !existing_record_ids('data').include?(r['link'])}
    end

    def save_animals(animals)
      records = animals.map(&:to_hash).map {|a| a.reject {|k,v| k == 'images'}}
      log.info("Saving #{records.size} animal records")
      ScraperWiki.save_sqlite(%w(link), records, 'data')
    end

    def new_images(other_images)
      other_images.select {|r| !existing_record_ids('images').include?(r.id)}
    end

    def save_images(images)
      records = images.map(&:to_hash)
      log.info("Saving #{records.size} image records")
      ScraperWiki.save_sqlite(%w(link), records, 'images')
    end

    def new_groups(new_groups)
      []
    end

    def animals_count
      ScraperWiki.select('count(id) as count from data').first['count']
    rescue SqliteMagic::NoSuchTable
      0
    end

    def groups_count
      ScraperWiki.select('count(id) as count from groups').first['count']
    rescue SqliteMagic::NoSuchTable
      0
    end

    def existing_record_ids(table='data', id='link')
      @cached ||= {}
      if @cached[table]
        return @cached[table]
      else
        @cached[table] = ScraperWiki.select("#{id} from #{table}").map {|r| r[id]}
      end
    rescue SqliteMagic::NoSuchTable
      []
    end
  end

  module Fetcher
    include Log

    def get(url, cache: true, format: :html)
      @agent ||= HTTParty

      case
      # Cache bypass
      when !cache
        log.debug("Cache bypass: #{url}")
        response = @agent.get(url, format: format)
      # Cache hit
      when cached?(url)
        log.debug("Cache hit: #{url}")
        response = cache_fetch(url)
      # Cache miss
      else
        log.debug("Cache miss: #{url}")
        response = @agent.get(url, format: format)
        response = cache_store(url, response.body.to_s)
      end

      case format
      when :html
        Nokogiri::HTML(response)
      when :json
        JSON.parse(response)
      else
        raise 'unsupported format'
      end
    end

    def cache_path(url)
      base = Pathname.new(__FILE__).parent.join('cache')
      hash = Digest::MD5.hexdigest(url)
      directory = base.join(hash[0])
      directory.mkpath unless directory.directory?
      directory.join(hash[1..-1])
    end

    def cache_store(url, content)
      cache_path(url).open('w') {|f| f << content} unless cached?(url)
      content
    end

    def cached?(url)
      cache_path(url).exist?
    end

    def cache_fetch(url)
      cache_path(url).read
    end
  end

  class Index
    include Log
    include Fetcher

    def animals
      return @animals if @animals

      log.debug("Species to fetch: #{species.join(',')}")
      @animals = species.map {|species|
        build_animal_index(:species => species)
      }.flatten
    end

    def species
      if ENV['MORPH_SPECIES']
        ENV['MORPH_SPECIES'].split(' ')
      else
        %w(dogs cats other)
      end
    end

    def build_animal_index(species:)
      log.debug("Building index for #{species}")

      plural   = ActiveSupport::Inflector.pluralize(species).capitalize
      singular = ActiveSupport::Inflector.singularize(species).capitalize

      base     = 'https://www.petrescue.com.au/listings/ryvuss_data'
      per_page = 60
      index    = 0
      query    = {
        'q'        => "Species.#{singular}.",
        'skip'     => index,
        'per_page' => per_page
      }
      url = Addressable::URI.parse(base)
      url.query_values = query

      response = get(url, :format => :json)
      max = response['Count']

      urls = index.step(max,per_page).to_a.map do |n|
        url = Addressable::URI.parse(base)
        url.query_values = {
          'q'        => "Species.#{singular}.",
          'skip'     => n,
          'per_page' => per_page
        }
        url.to_s
      end

      urls.map { |url|
        log.debug("Fetching index: #{url}")
        get(url, :format => :json)['SearchResults'].map {|animal|
          { 'link' => "http://www.petrescue.com.au/listings/#{animal['Id']}"}
        }
      }
    end

    def groups
      []
    end
  end

  class Animal
    include Log
    include Fetcher

    def initialize(attrs)
      @attrs = attrs
    end

    def scrape_details
      log.debug("Fetching page #{@attrs['link']}")
      page = get(@attrs['link'], format: :html, cache: cache_details?)

      # Attributes across all, regardless of adoption status
      @attrs.merge!({
        'status'       => adoption_status(page),
        'fostered_by'  => extract_listing_details(page, /rescue group/i) {|el| el.search('a').first['href'][/(\d+)/, 1].to_i },
        'state'        => extract_listing_details(page, /location/i) {|el| el.text },
        'images'       => extract_image_urls(page),
        'last_updated' => page.search('p.last_updated_at time').first['datetime'],
        'scraped_at'   => Time.now.iso8601,
      })

      # Extra attributes displayed on animals available for adoption
      if available?
        @attrs.merge!({
          'age'          => page.search('dl.pets-details dd.age').text,
          'adoption_fee' => page.search('dl.pets-details dd.adoption_fee').text,
          'desexed'      => bool(page.search('dl.pets-details dd.desexed').text),
          'vaccinated'   => bool(page.search('dl.pets-details dd.vaccinated').text),
          'wormed'       => bool(page.search('dl.pets-details dd.wormed').text),
          'heart_worm_treated' => bool(page.search('dl.pets-details dd.heart_worm_treated').text),
          'description'  => ReverseMarkdown.convert(page.search('div.personality').to_s),
          'interstate'   => (!!(page.search('h5.interstate').text =~ /^Not available/)).to_s,
        })
      end

      @attrs
    end

    def available?
      @attrs['status'] == 'available'
    end

    def to_h
      @attrs
    end

    alias_method :to_hash, :to_h

    def images
      @attrs['images']
    end

    def id
      @attrs['link']
    end

    protected

    def cache_details?
      if ENV['MORPH_CACHE_DETAILS']
        ENV['MORPH_CACHE_DETAILS'] =~ /true/i
      else
        true
      end
    end

    def bool(text)
      (text =~ /yes/i ? true : false).to_s
    end

    def adoption_status(page)
      if banner = page.search('div.status-banner').first
        banner.text.strip.downcase
      else
        'available'
      end
    end

    def save_and_open(page)
      require 'launchy'
      file = Tempfile.new
      file << page
      file.close

      Launchy.open(file.path)
    end

    def extract_listing_details(page, regex, &block)
      dl = page.search('dl.pet-listing__list.rescue-details')
      dt = dl.last.search('dt').find {|dt| dt.text =~ regex}
      if dt
        dd = dt.next
        until dd.name == 'dd'
          dd = dd.next
        end
        yield(dd)
      else
        nil
      end
    end

    def extract_image_urls(page)
      page.search('#thumbnails > li > a img').map {|img|
        img['src']
      }.map {|url|
        url.gsub(/([wh])_\d+/, '\1_638')
      }
    end
  end

  class Image
    def self.generate(animal)
      animal.images.map {|img|
        self.new(animal_id: animal.id, link: img)
      }.flatten
    end

    def initialize(animal_id:, link:)
      @attrs = { 'animal_id' => animal_id, 'link' => link }
    end

    def to_h
      @attrs
    end

    alias_method :to_hash, :to_h

    def id
      @attrs['link']
    end
  end
end


def main
  include PetRescue::Log

  db = PetRescue::Scraped.new
  index = PetRescue::Index.new

  # Animals
  new_animals = db.new_animals(index.animals)
  log.info("Existing animal records: #{db.animals_count}")
  log.info("New animal records:      #{new_animals.size}")

  new_animals.each_slice(10) do |slice|
    # Animals
    animals = slice.map {|attrs| PetRescue::Animal.new(attrs) }
    animals.each(&:scrape_details)
    db.save_animals(animals)

    # Images
    images = animals.map {|animal| PetRescue::Image.generate(animal)}.flatten
    new_images = db.new_images(images)
    db.save_images(new_images)
  end

  # Groups
  new_groups = db.new_groups(index.groups)
  log.info("Existing group records: #{db.groups_count}")
  log.info("New group records:      #{new_groups.size}")

  new_groups.each_slice(10) do |slice|
    groups = slice.map {|attrs| PetRescue::Group.new(attrs) }
    groups.each(&:scrape_details)
    db.save_groups(groups)
  end
end

main
