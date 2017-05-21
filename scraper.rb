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
      other_animals.select {|r| !existing_record_ids(table: 'animals').include?(r.id)}
    end

    def new_images(other_images)
      other_images.select {|r| !existing_record_ids(table: 'images').include?(r.id)}
    end

    def new_groups(other_groups)
      other_groups.select {|r| !existing_record_ids(table: 'groups').include?(r.id)}
    end

    def save_animals(animals)
      records = animals.map(&:to_hash).map {|a| a.reject {|k,v| k == 'images'}}
      log.info("Saving #{records.size} animal records")
      ScraperWiki.save_sqlite(%w(link), records, 'animals')
    end

    def save_images(images)
      records = images.map(&:to_hash)
      log.info("Saving #{records.size} image records")
      ScraperWiki.save_sqlite(%w(link), records, 'images')
    end

    def save_groups(groups)
      records = groups.map(&:to_hash)
      log.info("Saving #{records.size} group records")
      ScraperWiki.save_sqlite(%w(link), records, 'groups')
    end

    def animals_count
      ScraperWiki.select('count(link) as count from animals').first['count']
    rescue SqliteMagic::NoSuchTable
      0
    end

    def images_count
      ScraperWiki.select('count(link) as count from images').first['count']
    rescue SqliteMagic::NoSuchTable
      0
    end

    def groups_count
      ScraperWiki.select('count(link) as count from groups').first['count']
    rescue SqliteMagic::NoSuchTable
      0
    end

    def existing_record_ids(table: 'animals', id: 'link')
      @cached ||= {}
      if @cached[table]
        return @cached[table]
      else
        @cached[table] = ScraperWiki.select("#{id} from #{table}").map {|r| r[id]}
      end
    rescue SqliteMagic::NoSuchTable
      []
    end

    def upgrade_tables
      # data => animals
      results = ScraperWiki.sqliteexecute(%(SELECT name FROM sqlite_master WHERE type='table' AND name='data';))
      unless results.empty?
        log.info("Renaming table `data` to `animals`")
        ScraperWiki.sqliteexecute('ALTER TABLE data RENAME TO animals')
      end

      # fostered_by => group_id (animals)
      # id => nil (animals)
      results = ScraperWiki.sqliteexecute(%(PRAGMA table_info('animals')))
      if results.find {|r| r['name'] == 'fostered_by'}
        log.info("Renaming `fostered_by` column to `group_id` on `animals` table")
        log.info("Removing `id` column from `animals` table")
        temporary_table_name = "animals_#{Time.now.to_i}"
        statements = [
          %(ALTER TABLE animals RENAME TO #{temporary_table_name};),
          %(CREATE TABLE animals (name,description,gender,breed,link,type,age,adoption_fee,desexed,vaccinated,wormed,heart_worm_treated,group_id,state,interstate,times_viewed,last_updated, scraped_at, status, UNIQUE (link));),
          %(INSERT INTO animals (name,description,gender,breed,link,type,age,adoption_fee,desexed,vaccinated,wormed,heart_worm_treated,group_id,state,interstate,times_viewed,last_updated, scraped_at, status) SELECT name,description,gender,breed,link,type,age,adoption_fee,desexed,vaccinated,wormed,heart_worm_treated,fostered_by,state,interstate,times_viewed,last_updated,scraped_at,status FROM #{temporary_table_name};),
          %(DROP TABLE #{temporary_table_name};),
        ]
        statements.each {|statement| ScraperWiki.sqliteexecute(statement)}
      end
    end

    def backfill_data
      records = ScraperWiki.sqliteexecute("SELECT * FROM animals WHERE group_id NOT LIKE 'http%'")
      log.info("Fixing #{records.size} animal records")

      updated_records = records.map {|record|
        record.merge({'group_id' => "https://www.petrescue.com.au/groups/#{record['group_id']}"})
      }

      save_animals(updated_records)
    end
  end

  module Fetcher
    include Log

    def get(url, cache: true, format: :html)
      @agent ||= HTTParty

      case
      # Cache refresh
      when cache == :refresh
        log.debug("Cache refresh: #{url}")
        response = @agent.get(url, format: format)
        response = cache_store(url, response.body.to_s)
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
        response.is_a?(String) ? JSON.parse(response) : response
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

    attr_reader :base

    def initialize
      @base = 'https://www.petrescue.com.au'
    end

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

      path     = '/listings/ryvuss_data'
      url      = base + path
      per_page = 60
      index    = 0
      query    = {
        'q'        => "Species.#{singular}.",
        'skip'     => index,
        'per_page' => per_page
      }
      url = Addressable::URI.parse(url)
      url.query_values = query

      response = get(url, :cache => cache_index?, :format => :json)
      max = response['Count']

      urls = index.step(max,per_page).to_a.map do |n|
        url = Addressable::URI.parse(base + path)
        url.query_values = {
          'q'        => "Species.#{singular}.",
          'skip'     => n,
          'per_page' => per_page
        }
        url.to_s
      end

      urls.map { |url|
        log.debug("Fetching index: #{url}")
        results = get(url, cache: cache_index?, :format => :json)['SearchResults']
        results.map {|animal|
          attrs = { 'link' => "http://www.petrescue.com.au/listings/#{animal['Id']}"}
          Animal.new(attrs)
        }
      }
    end

    def cache_index?
      value = ENV['MORPH_CACHE_INDEX']
      case
      when value =~ /refresh/i
        :refresh
      when value =~ /true|yes|y/i
        true
      when value =~ /false|no|n/i
        false
      else
        true
      end
    end

    def groups
      path = '/rescue_directory'
      url  = base + path

      response = get(url, cache: cache_index?, :format => :html)
      href     = response.search('nav.pagination span.last a').first['href']
      max      = Addressable::URI.parse(href).query_values['page'].to_i

      urls = 1.upto(max).to_a.map { |n|
        url = Addressable::URI.parse(base + path)
        url.query_values = { 'page' => n }
        url.to_s
      }

      urls.map {|url|
        log.debug("Fetching index: #{url}")
        response = get(url, cache: cache_index?, :format => :html)
        extract_groups_from_page(response)
      }.flatten.uniq
    end

    def extract_groups_from_page(page)
      links = page.search('div.search-listing-copy a.rescue-directory__group__name')
      links.map {|link|
        attrs = { 'name' => link.text.strip, 'link' => base + link['href'] }
        PetRescue::Group.new(attrs)
      }
    end
  end

  class Group
    include Log
    include Fetcher

    def initialize(attrs)
      @attrs = attrs
    end

    def id
      @attrs['link']
    end

    def to_hash
      @attrs
    end

    alias_method :to_h, :to_hash

    def scrape_details
      log.debug("Fetching page #{@attrs['link']}")
      page = get(@attrs['link'], format: :html, cache: cache_details?)

      titles = page.search('h2.rescue-group__section-title')

      @attrs.merge!({
        'about'            => ReverseMarkdown.convert(titles.first.next.next),
        'adoption_process' => ReverseMarkdown.convert(titles.last.next.next),
        'states'           => page.search('p.rescue-group__header__active-in').text.strip[/.+:\s+(.+)/, 1],
      })

      page.search('div.rescue-group__social-contacts a').map {|a|
        { a['class'] => a['href'] }
      }.uniq.each {|hash|
        @attrs.merge!(hash)
      }

      if page.search('dl.rescue-group__contact-details').size > 0
        @attrs['contact_name'] = extract_group_details(page, /contact name:/i) {|dd| dd.text.strip }
        @attrs['phone_number_1'] = extract_group_details(page, /Phone number(\s+1)*:/i) {|dd| dd.text.strip }
        @attrs['phone_number_2'] = extract_group_details(page, /Phone number 2:/i) {|dd| dd.text.strip }
        @attrs['phone_number_3'] = extract_group_details(page, /Phone number 3:/i) {|dd| dd.text.strip }

        binding.pry unless page.search('dl.rescue-group__contact-details').first&.search('dt').map(&:text).reject {|r| r =~ /name|number/i}.empty?
      end
    end

    def phone_number_1
      @attrs['phone_number_1']
    end

    protected

    def cache_details?
      value = ENV['MORPH_CACHE_DETAILS']
      case
      when value =~ /true|yes|y/i
        true
      when value =~ /false|no|n/i
        false
      when value =~ /refresh/i
        :refresh
      else
        true
      end
    end

    def extract_group_details(page, regex, &block)
      dl = page.search('dl.rescue-group__contact-details')
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
  end

  class Animal
    include Log
    include Fetcher

    attr_reader :base

    def initialize(attrs)
      @base  = 'https://www.petrescue.com.au'
      @attrs = attrs
    end

    def scrape_details
      log.debug("Fetching page #{@attrs['link']}")
      page = get(@attrs['link'], format: :html, cache: cache_details?)

      # Attributes across all, regardless of adoption status
      @attrs.merge!({
        'status'       => adoption_status(page),
        'group_id'     => extract_listing_details(page, /rescue group/i) {|el| base + el.search('a').first['href'] },
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

    def to_hash
      @attrs
    end

    alias_method :to_h, :to_hash

    def images
      @attrs['images']
    end

    def id
      @attrs['link']
    end

    protected

    def cache_details?
      value = ENV['MORPH_CACHE_DETAILS']
      case
      when value =~ /true|yes|y/i
        true
      when value =~ /false|no|n/i
        false
      when value =~ /refresh/i
        :refresh
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

    def to_hash
      @attrs
    end

    alias_method :to_h, :to_hash

    def id
      @attrs['link']
    end
  end
end


def main
  include PetRescue::Log

  db = PetRescue::Scraped.new
  index = PetRescue::Index.new

  db.upgrade_tables

  # Animals
  new_animals = db.new_animals(index.animals)
  log.info("Existing animal records: #{db.animals_count}")
  log.info("New animal records:      #{new_animals.size}")

  new_animals.each_slice(10) do |animals|
    # Animals
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

  new_groups.each_slice(10) do |groups|
    groups.each(&:scrape_details)
    db.save_groups(groups)
  end

  db.backfill_data
end

main

# TODO(auxesis): move to separate files
# TODO(auxesis): rename fostered_by column to group_id
# TODO(auxesis): backfill microchip numbers
# TODO(auxesis): identify animal data that is not being scraped
# TODO(auxesis): add rubocop, and build with travis
