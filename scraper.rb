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

def cache_path(url)
  base = Pathname.new(__FILE__).parent.join('cache')
  hash = Digest::MD5.hexdigest(url)
  directory = base.join(hash[0])
  directory.mkpath unless directory.directory?
  directory.join(hash[1..-1])
end

def cache_store(url, content)
  cache_path(url).open('w') {|f| f << content} unless cached?(url)
  Nokogiri::HTML(content)
end

def cached?(url)
  cache_path(url).exist?
end

def cache_fetch(url)
  body = cache_path(url).read
  Nokogiri::HTML(body)
end

def get(url, opts={})
  options = {
    :cache => true
  }.merge!(opts)
  @agent ||= Mechanize.new

  case
  # Cache bypass
  when !options[:cache]
    page = @agent.get(url)
  # Cache hit
  when cached?(url)
    cache_fetch(url)
  # Cache miss
  else
    page = @agent.get(url)
    cache_store(url, page.body.to_s)
  end
end

def extract_listings(page, species)
  page.search("li.#{species}-listing.listing").map do |listing|
    {
      'name' => listing.search('h4').text.strip,
      'description' => listing.search('div.personality').text,
      'gender' => listing.search('dd.gender').first.text.downcase,
      'breed' => listing.search('dd.breed').first.text,
      'link' => 'https://www.petrescue.com.au' + listing.search('h4 a').first['href'],
      'species' => species,
      'id'   => listing.search('h4 a').first['href'][/(\d+)$/, 1]
    }
  end
end

def species
  if ENV['MORPH_SPECIES']
    ENV['MORPH_SPECIES'].split(' ')
  else
    %w(dogs cats other)
  end
end

def cache_index?
  if ENV['MORPH_CACHE_INDEX']
    ENV['MORPH_CACHE_INDEX'] =~ /true/i
  else
    true
  end
end

def cache_details?
  if ENV['MORPH_CACHE_DETAILS']
    ENV['MORPH_CACHE_DETAILS'] =~ /true/i
  else
    true
  end
end

module PetRescue
  class Search
    include HTTParty
    base_uri 'www.petrescue.com.au'
  end
end

def build_animal_index(species: 'dog')
  puts "[debug] Building index for #{species}"

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

  response = HTTParty.get(url)
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

  data = urls.map { |url|
    puts "[debug] Fetching index: #{url}"
    HTTParty.get(url)['SearchResults'].map {|animal|
      { 'link' => "http://www.petrescue.com.au/listings/#{animal['Id']}"}
    }
  }.flatten
  data
end

def all_animals
  return @animals if @animals

  puts "[debug] Species to fetch: #{species.join(',')}"
  @animals = species.map {|species|
    animals = build_animal_index(:species => species)
  }.flatten
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

def fetch_details(a)
  puts "[debug] Fetching page #{a['link']}"
  page = get(a['link'], cache: cache_details?)

  if adoption_status(page) == 'available'
    a.merge({
      'status'       => adoption_status(page),
      'age'          => page.search('dl.pets-details dd.age').text,
      'adoption_fee' => page.search('dl.pets-details dd.adoption_fee').text,
      'desexed'      => bool(page.search('dl.pets-details dd.desexed').text),
      'vaccinated'   => bool(page.search('dl.pets-details dd.vaccinated').text),
      'wormed'       => bool(page.search('dl.pets-details dd.wormed').text),
      'heart_worm_treated' => bool(page.search('dl.pets-details dd.heart_worm_treated').text),
      'fostered_by'  => extract_listing_details(page, /rescue group/i) {|el| text.search('a').first['href'][/(\d+)/, 1].to_i },
      'description'  => ReverseMarkdown.convert(page.search('div.personality').to_s),
      'state'        => extract_listing_details(page, /location/i) {|el| el.text },
      'interstate'   => (!!(page.search('h5.interstate').text =~ /^Not available/)).to_s,
      'last_updated' => page.search('p.last_updated_at time').first['datetime'],
      'images'       => extract_image_urls(page),
      'scraped_at'   => Time.now.iso8601,
    })
  else
    a.merge({
      'status'       => adoption_status(page),
      'fostered_by'  => extract_rescue_group(page),
      'state'        => extract_state(page),
      'images'       => extract_image_urls(page),
      'last_updated' => page.search('p.last_updated_at time').first['datetime'],
    })
  end
end

def save_images(animals)
  # Save any images that we've picked up by scraping animals
  images = animals.map { |a|
    if a['images']
      a.delete('images').map {|url|
        { 'animal_id' => a['link'], 'link' => url }
      }
    else
      []
    end
  }.flatten

  new_images = images.select {|r| !existing_record_ids('images').include?(r['link'])}
  puts "[info] There are #{new_images.size} new image records"
  puts "[info] Saving #{new_images.size} image records"
  ScraperWiki.save_sqlite(%w(link), new_images, 'images')
end

def main
  # Scrape the index, work out what the new records are.
  new_animals = all_animals.select {|r| !existing_record_ids.include?(r['link'])}
  puts "[info] There are #{existing_record_ids.size} existing animal records"
  puts "[info] There are #{new_animals.size} new animal records"

  # Work through 10 records at a time to get more details for each record.
  # This allows the scraper to resume runs and save partial results.
  new_animals.each_slice(10) do |slice|
    # Add more attributes to any new records we've found.
    new_animal_slice = slice.map {|a| fetch_details(a) }
    # Extract images we've found when finding details for each record.
    save_images(new_animal_slice)

    # Then save the animals
    puts "[info] Saving #{new_animal_slice.size} animal records"
    begin
      ScraperWiki.save_sqlite(%w(link), new_animal_slice)
    rescue RuntimeError => e
      binding.pry
    end
  end
end

main
