require 'scraperwiki'
require 'mechanize'
require 'pry'
require 'reverse_markdown'
require 'active_support/inflector'
require 'nokogiri'
require 'time'

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

def extract_listings(page, type)
  page.search("li.#{type}-listing.listing").map do |listing|
    {
      'name' => listing.search('h4').text.strip,
      'description' => listing.search('div.personality').text,
      'gender' => listing.search('dd.gender').first.text.downcase,
      'breed' => listing.search('dd.breed').first.text,
      'link' => 'https://www.petrescue.com.au' + listing.search('h4 a').first['href'],
      'type' => type,
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

def all_animals
  return @animals if @animals

  puts "[debug] Species to fetch: #{species.join(',')}"
  @animals = species.map {|type|
    plural   = ActiveSupport::Inflector.pluralize(type)
    singular = ActiveSupport::Inflector.singularize(type)

    puts "[debug] Fetching #{plural} index"
    url  = "https://www.petrescue.com.au/listings/#{type}"
    page = get(url, cache: cache_index?)
    max  = page.search('#main > article > div.pagination.footer-pagination > nav > div.info').first.text.split.last.to_i

    animals = (1..max).to_a.map { |i|
      puts "[debug] Fetching page #{i} of #{max} for #{plural}"
      url  = "https://www.petrescue.com.au/listings/#{type}?page=#{i}"
      page = get(url, cache: cache_index?)
      extract_listings(page, singular)
    }.flatten
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

def fetch_details(a)
  puts "[debug] Fetching page #{a['link']}"
  page = get(a['link'], cache: cache_details?)
  a.merge({
    'age'          => page.search('dl.pets-details dd.age').text,
    'adoption_fee' => page.search('dl.pets-details dd.adoption_fee').text,
    'desexed'      => bool(page.search('dl.pets-details dd.desexed').text),
    'vaccinated'   => bool(page.search('dl.pets-details dd.vaccinated').text),
    'wormed'       => bool(page.search('dl.pets-details dd.wormed').text),
    'heart_worm_treated' => bool(page.search('dl.pets-details dd.heart_worm_treated').text),
    'fostered_by'  => page.search('dl.pets-details dd.fostered_by a').first['href'][/(\d+)/, 1].to_i,
    'description'  => ReverseMarkdown.convert(page.search('div.personality').to_s),
    'state'        => page.search('h4.located_in').text[/^Located in (.+)/, 1],
    'interstate'   => (!(page.search('h5.interstate').text =~ /^Not available/)).to_s,
    'times_viewed' => page.search('p.view_count').text[/(\d+)/,1].to_i,
    'last_updated' => page.search('p.last_updated_at time').first['datetime'],
    'images'       => page.search('#thumbnails > li > a').map {|a| a['href']},
    'scraped_at'   => Time.now.iso8601,
  })
end

def save_images(animals)
  # Save any images that we've picked up by scraping animals
  images = animals.map { |a|
    a.delete('images').map {|url|
      { 'animal_id' => a['link'], 'link' => url }
    }
  }.flatten

  new_images = images.select {|r| !existing_record_ids('images').include?(r['link'])}
  puts "[info] There are #{new_images.size} new image records"
  puts "[info] Saving #{new_images.size} image records"
  ScraperWiki.save_sqlite(%w(link), new_images, 'images')
end

def main
  # Scrape the index, work out what the new records are.
  puts "[info] There are #{existing_record_ids.size} existing animal records"
  new_animals = all_animals.select {|r| !existing_record_ids.include?(r['link'])}
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

def backfill
  begin
    ScraperWiki.sqliteexecute('ALTER TABLE data ADD scraped_at')
  rescue SQLite3::SQLException => e
    raise e unless e.message == 'duplicate column name: scraped_at'
  end

  records = ScraperWiki.select('* from data where scraped_at is null')
  if records.size > 0
    puts "[info] #{records.size} records to backfill scraped_at"
    records.each {|r| r['scraped_at'] = Time.now.iso8601}
    ScraperWiki.save_sqlite(%w(link), records)
  else
    puts '[info] No records to backfill scraped_at'
  end
end

main
backfill
