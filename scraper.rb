require 'scraperwiki'
require 'mechanize'
require 'pry'

def get(url)
  @agent ||= Mechanize.new
  @agent.get(url)
end

def extract_listings(page)
  page.search('li.dog-listing.listing').map do |listing|
    {
      'name' => listing.search('h4').text,
      'description' => listing.search('div.personality').text,
      'gender' => listing.search('dd.gender').first.text.downcase,
      'breed' => listing.search('dd.breed').first.text,
      'link' => 'https://www.petrescue.com.au' + listing.search('h4 a').first['href'],
    }
  end
end

def fetch_animals(url)
  page = get(url)
  extract_listings(page)
end

def main
  url = 'https://www.petrescue.com.au/listings/dogs?age=either&commit=Search&gender=either&page=1&postcode=&postcode_distance=50&size%5B%5D=all&species=dog&states%5B%5D=1&utf8=%E2%9C%93'
  page = get(url)
  max = page.search('#main > article > div.pagination.footer-pagination > nav > div.info').first.text.split.last.to_i

  animals = (1..max).to_a.map { |i|
    puts "### Fetching page #{i} of #{max}"
    url = "https://www.petrescue.com.au/listings/dogs?age=either&commit=Search&gender=either&page=#{i}&postcode=&postcode_distance=50&size%5B%5D=all&species=dog&states%5B%5D=1&utf8=%E2%9C%93"
    fetch_animals(url)
  }.flatten

  puts "### Saving #{animals.size} records"

  ScraperWiki.save_sqlite(%w(link), animals)
end

main

